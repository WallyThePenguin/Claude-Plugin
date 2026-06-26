# Dev-bridge Hot-Reload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply plugin code changes to the running Studio plugin in ~1s via `& scripts/studio-agent.ps1 reload`, with NO Studio restart (only a tiny stable bootstrap is exempt).

**Architecture:** Split the entry into a STABLE bootstrap (`init.server.luau` — toolbar/widget + a supervisor loop) and a RELOADABLE `Main.luau` (everything else). A `reload` command makes the sidecar read `src/**/*.luau` from disk and hand it to the plugin; `HotReload` clones the module tree, writes the fresh source onto the clones, `require`s the fresh `Main` (transitively fresh `Tools`/engine), and swaps the running generation via a per-generation `Lifecycle` (tears down the old loop/connections/UI). A broken reload keeps the old generation alive.

**Tech Stack:** Luau (`--!strict`), Roblox plugin (`Instance:Clone()` + writable `ModuleScript.Source` at PluginSecurity), the Python stdlib sidecar (`bridge.py`/`server.py`), `scripts/studio-agent.ps1`, Rojo, `selene`/`stylua`, the dev bridge.

---

## File Structure

- **Modify `sidecar/bridge.py`** — `Store` gains a reload flag + reload-result map.
- **Modify `sidecar/server.py`** — `/reload`, `/reload/pending` (reads `src/`), `/reload/result` endpoints + `read_src_sources()`.
- **Modify `sidecar/test_bridge.py`** — reload Store tests.
- **Create `sidecar/test_server.py`** — a `read_src_sources()` smoke test.
- **Modify `scripts/studio-agent.ps1`** — a `reload` subcommand.
- **Create `src/HotReload.luau`** — `newLifecycle` + `resolvePath` (pure) + `reload` + `startSupervisor` (impure). STABLE core (required by the bootstrap).
- **Create `src/HotReloadSpec.luau`** — pure tests for `resolvePath` + `newLifecycle`.
- **Create `src/Main.luau`** — the reloadable entry: `Main.run(ctx) -> Lifecycle`.
- **Modify `src/DevBridge.luau`** — `DevBridge.start(deps, lifecycle)`: loop exits when `lifecycle.cancelled`.
- **Modify `src/init.server.luau`** — thin bootstrap: toolbar/widget + `runtime` + gen-1 `Main.run` + `HotReload.startSupervisor`.

**Testing notes:** Python tests run with `python sidecar/test_X.py` (no pytest; a manual runner at the bottom returns exit 0/1). Luau specs run in-Studio (or via the bridge: `& scripts/studio-agent.ps1 luau 'return tostring(require(script.Parent.HotReloadSpec).run())'`). Per-task static gate: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene 0/0). Run Python from `sidecar/` so the `from bridge import Store` / `from server import ...` imports resolve.

---

### Task 1: Sidecar reload channel (Store + endpoints + tests)

**Files:** Modify `sidecar/bridge.py`; Modify `sidecar/server.py`; Modify `sidecar/test_bridge.py`; Create `sidecar/test_server.py`.

- [ ] **Step 1: Write the failing Store tests**

In `sidecar/test_bridge.py`, add these two functions (after `test_submit_overwrites_single_slot`, before the `if __name__` runner):

```python
def test_request_reload_then_take_clears():
    s = Store()
    rid = s.request_reload()
    assert rid == 1
    assert s.take_reload() == {"id": 1}
    assert s.take_reload() is None  # cleared after taking


def test_reload_result_roundtrip():
    s = Store()
    s.put_reload_result(3, {"ok": True})
    assert s.get_reload_result(3) == {"ok": True}
    assert s.get_reload_result(4) is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python sidecar/test_bridge.py`
Expected: FAIL — `AttributeError: 'Store' object has no attribute 'request_reload'` (the runner reports a crash / the two new tests don't pass).

- [ ] **Step 3: Add the reload state to `Store` (`sidecar/bridge.py`)**

In `Store.__init__`, after `self._logs = []`, add:

```python
        self._reload = None       # {"id": N} when a reload is requested, else None
        self._reload_counter = 0
        self._reload_results = {}  # reload id -> result dict
```

Then add these methods to `Store` (after `get_logs`):

```python
    def request_reload(self) -> int:
        """Flag a reload (separate from the command queue). Returns its id."""
        with self._lock:
            self._reload_counter += 1
            self._reload = {"id": self._reload_counter}
            return self._reload_counter

    def take_reload(self):
        """Return the pending reload request and clear it, or None."""
        with self._lock:
            r = self._reload
            self._reload = None
            return r

    def put_reload_result(self, reload_id: int, result: dict):
        with self._lock:
            self._reload_results[int(reload_id)] = result

    def get_reload_result(self, reload_id: int):
        with self._lock:
            return self._reload_results.get(int(reload_id))
```

- [ ] **Step 4: Run the Store tests to verify they pass**

Run: `python sidecar/test_bridge.py`
Expected: PASS — `7/7 passed`, exit 0.

- [ ] **Step 5: Add `read_src_sources()` + endpoints (`sidecar/server.py`)**

In `sidecar/server.py`, after the imports and `STORE = Store()` line, add the source reader:

```python
SRC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")


def read_src_sources() -> dict:
    """Read every src/**/*.luau into {relativePosixPath: source}. Used by the hot-reload channel; the
    sidecar must be run from source (not the frozen exe) for src/ to resolve."""
    sources = {}
    for root, _dirs, files in os.walk(SRC_DIR):
        for name in files:
            if name.endswith(".luau"):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, SRC_DIR).replace(os.sep, "/")
                with open(full, "r", encoding="utf-8") as fh:
                    sources[rel] = fh.read()
    return sources
```

In `do_GET`, add these two branches (before the final `return self._json(404, ...)`):

```python
        if parsed.path == "/reload/pending":
            r = STORE.take_reload()
            if r is None:
                return self._json(200, {"requested": False})
            try:
                sources = read_src_sources()
            except Exception as exc:  # noqa: BLE001
                return self._json(200, {"requested": True, "id": r["id"], "error": str(exc)})
            return self._json(200, {"requested": True, "id": r["id"], "sources": sources})
        if parsed.path == "/reload/result":
            try:
                rid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            res = STORE.get_reload_result(rid)
            return self._json(200, res if res is not None else {"status": "pending"})
```

In `do_POST`, add these two branches (before the final `return self._json(404, ...)`):

```python
        if parsed.path == "/reload":
            return self._json(200, {"id": STORE.request_reload()})
        if parsed.path == "/reload/result":
            rid = body.get("id")
            if not isinstance(rid, int):
                return self._json(400, {"error": "reload result needs an integer id"})
            STORE.put_reload_result(rid, body)
            return self._json(200, {"ok": True})
```

Also extend the module docstring's endpoint list (top of `server.py`) with the new routes (purely documentation — add under the existing `POST /logs` line):

```
POST /reload                                              -> {"id":N}  (flags a hot-reload)
GET  /reload/pending                                      -> {"requested":bool,"id":N,"sources":{...}}
POST /reload/result {"id":N,"ok":bool,"error":?}          -> {"ok":true}
GET  /reload/result?id=N                                  -> the reload outcome, or {"status":"pending"}
```

- [ ] **Step 6: Write + run the server source-reader test (`sidecar/test_server.py`)**

Create `sidecar/test_server.py`:

```python
"""Smoke test for the hot-reload source reader. Run: python sidecar/test_server.py (no pytest needed)."""
from server import read_src_sources


def test_reads_known_luau_modules():
    sources = read_src_sources()
    assert isinstance(sources, dict)
    # A known existing module is present, keyed by its src-relative posix path.
    assert "AnimationClip.luau" in sources
    assert "Tools/init.luau" in sources
    # Values are non-empty Luau source.
    assert sources["AnimationClip.luau"].strip() != ""
    # The bootstrap is included in the raw read (the PLUGIN side skips it, not the reader).
    assert "init.server.luau" in sources


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"FAIL {fn.__name__}: {e}")
    print(f"{passed}/{len(fns)} passed")
    raise SystemExit(0 if passed == len(fns) else 1)
```

Run (from the repo root): `python sidecar/test_server.py`
Expected: PASS — `1/1 passed`, exit 0. (Run from `sidecar/`'s perspective — the `from server import` resolves because `server.py` is in `sidecar/`; invoke as `python sidecar/test_server.py` from the repo root, which puts `sidecar/` on `sys.path[0]`.)

- [ ] **Step 7: Commit**

```bash
git add sidecar/bridge.py sidecar/server.py sidecar/test_bridge.py sidecar/test_server.py
git commit -m "feat(sidecar): hot-reload channel — /reload + /reload/pending (reads src/) + /reload/result + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `studio-agent.ps1 reload` subcommand

**Files:** Modify `scripts/studio-agent.ps1`.

- [ ] **Step 1: Add the `reload` branch**

In `scripts/studio-agent.ps1`, inside the `switch ($Command) { ... }`, add this branch after the `"logs"` branch (before `"capture"`):

```powershell
    "reload" {
        $r = Invoke-RestMethod -Method Post -Uri "$base/reload" -Body "{}" -ContentType "application/json"
        $id = $r.id
        $deadline = (Get-Date).AddSeconds(30)
        $done = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $res = Invoke-RestMethod -Method Get -Uri "$base/reload/result?id=$id"
            if ($res.PSObject.Properties.Name -contains "ok") {
                if ($res.ok) { "reload ok" } else { "reload FAILED: $($res.error)" }
                $done = $true
                break
            }
        }
        if (-not $done) { "reload: timed out waiting for the plugin (is Studio open with the bridge active?)" }
    }
```

- [ ] **Step 2: Update the usage comment + default case**

At the top of `scripts/studio-agent.ps1`, add a usage line under the `logs` one:

```powershell
#   .\studio-agent.ps1 reload                          hot-reload the plugin (no Studio restart)
```

And update the `default` branch text to include `reload`:

```powershell
    default { "unknown command: $Command (use tool|luau|prompt|logs|reload|capture)" }
```

- [ ] **Step 3: Static check**

Run: `pwsh -NoProfile -Command "Get-Command -Syntax ./scripts/studio-agent.ps1"` OR simply confirm the file parses by running it with no useful effect: `& scripts/studio-agent.ps1 logs` (it should still print logs, proving the script parses). The `reload` path is verified live in Task 6.
Expected: the script still runs `logs` without a parse error.

- [ ] **Step 4: Commit**

```bash
git add scripts/studio-agent.ps1
git commit -m "feat(bridge): studio-agent.ps1 reload subcommand (POST /reload + poll the outcome)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: HotReload pure helpers (`newLifecycle` + `resolvePath`) + spec

**Files:** Create `src/HotReload.luau`; Create `src/HotReloadSpec.luau`.

- [ ] **Step 1: Create `src/HotReload.luau` with the pure section only**

```lua
--!strict
-- HotReload: the dev-bridge hot-reload engine. Clones the plugin's module tree, writes fresh source onto
-- the clones, and re-requires Main so a code change applies with NO Studio restart. PURE resolvePath +
-- newLifecycle are unit-tested in HotReloadSpec; the impure reload/startSupervisor (clone + require +
-- swap + the poll loop) are added in Task 5 and live-verified. This module is the STABLE core (the
-- bootstrap requires it), so changes to HotReload itself still need a restart. See
-- docs/superpowers/specs/2026-06-26-dev-bridge-hot-reload-design.md.

local HotReload = {}

export type Lifecycle = {
	cancelled: boolean,
	connections: { RBXScriptConnection },
	add: (self: any, conn: RBXScriptConnection) -> (),
	cancel: (self: any) -> (),
}

-- A per-generation lifecycle: tracks event connections so a reload can disconnect them, and a `cancelled`
-- flag the dev-bridge loop checks each tick to exit. PURE (no DataModel reads).
function HotReload.newLifecycle(): Lifecycle
	local lc = { cancelled = false, connections = {} :: { RBXScriptConnection } }
	function lc.add(self, conn)
		table.insert(self.connections, conn)
	end
	function lc.cancel(self)
		self.cancelled = true
		for _, conn in self.connections do
			pcall(function()
				conn:Disconnect()
			end)
		end
		self.connections = {}
	end
	return lc :: any
end

-- Map a Rojo relative source path to (parentInstance, childName) within `container` so the caller can
-- find-or-create the ModuleScript and set its Source. "X/init.luau" targets the folder-module X itself;
-- "Tools/Animate.luau" targets Animate under Tools; "AnimationClip.luau" targets AnimationClip at the
-- root. Missing intermediate folders are created (as Folder). Returns (nil, nil) for the bootstrap
-- ("init.server.luau"), a bare root "init.luau", or a non-.luau path. PURE-ish (deterministic; only
-- creates intermediate Folders). Unit-tested.
function HotReload.resolvePath(container: Instance, relpath: string): (Instance?, string?)
	if relpath == "init.server.luau" then
		return nil, nil
	end
	local name = string.gsub(relpath, "%.luau$", "")
	if name == relpath then
		return nil, nil -- not a .luau file
	end
	local segs = string.split(name, "/")
	local targetName: string
	local parentSegs: { string } = {}
	if segs[#segs] == "init" then
		if #segs < 2 then
			return nil, nil -- a bare root init.luau has no folder-module to target
		end
		targetName = segs[#segs - 1]
		for i = 1, #segs - 2 do
			table.insert(parentSegs, segs[i])
		end
	else
		targetName = segs[#segs]
		for i = 1, #segs - 1 do
			table.insert(parentSegs, segs[i])
		end
	end
	local parent: Instance = container
	for _, seg in parentSegs do
		local child = parent:FindFirstChild(seg)
		if child == nil then
			local f = Instance.new("Folder")
			f.Name = seg
			f.Parent = parent
			child = f
		end
		parent = child
	end
	return parent, targetName
end

return HotReload
```

- [ ] **Step 2: Create `src/HotReloadSpec.luau`**

```lua
--!strict
-- HotReloadSpec: in-Studio self-test for the PURE HotReload helpers (resolvePath + newLifecycle). No
-- sidecar/clone/require. Run via require(script.HotReloadSpec).run() in init, OR from the bridge:
-- luau 'return tostring(require(script.Parent.HotReloadSpec).run())'.

local HotReload = require(script.Parent.HotReload)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

-- A synthetic clone container: AnimationClip (ModuleScript), Tools (ModuleScript) -> Animate
-- (ModuleScript), UI (Folder) -> Widget (ModuleScript).
local function sampleContainer(): Instance
	local c = Instance.new("Folder")
	c.Name = "container"
	local function ms(name: string, parent: Instance): ModuleScript
		local m = Instance.new("ModuleScript")
		m.Name = name
		m.Parent = parent
		return m
	end
	ms("AnimationClip", c)
	local tools = ms("Tools", c)
	ms("Animate", tools)
	local ui = Instance.new("Folder")
	ui.Name = "UI"
	ui.Parent = c
	ms("Widget", ui)
	return c
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("resolvePath: root module", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "AnimationClip.luau")
		return parent == c and child == "AnimationClip", "got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: nested module under a ModuleScript folder", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "Tools/Animate.luau")
		return parent == c:FindFirstChild("Tools") and child == "Animate",
			"got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: init.luau targets the folder-module itself", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "Tools/init.luau")
		return parent == c and child == "Tools", "got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: module under a plain Folder", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "UI/Widget.luau")
		return parent == c:FindFirstChild("UI") and child == "Widget",
			"got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: bootstrap is skipped", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "init.server.luau")
		return parent == nil and child == nil, "bootstrap should map to (nil,nil)"
	end)

	add("resolvePath: a new leaf module returns its (existing-parent, name)", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "NewModule.luau")
		return parent == c and child == "NewModule", "got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: a new nested path creates the intermediate Folder", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "NewFolder/NewMod.luau")
		local nf = c:FindFirstChild("NewFolder")
		return nf ~= nil and parent == nf and child == "NewMod",
			"intermediate folder not created or wrong target"
	end)

	add("newLifecycle: cancel sets the flag and disconnects connections", function()
		local lc = HotReload.newLifecycle()
		local disconnected = false
		lc:add({ Disconnect = function()
			disconnected = true
		end } :: any)
		if lc.cancelled then
			return false, "should start un-cancelled"
		end
		lc:cancel()
		return lc.cancelled and disconnected and #lc.connections == 0,
			"cancelled=" .. tostring(lc.cancelled) .. " disconnected=" .. tostring(disconnected)
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[HotReloadSpec] PASS " .. c.name)
		else
			warn("[HotReloadSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[HotReloadSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (The spec runs in-Studio at Task 6.)

- [ ] **Step 4: Commit**

```bash
git add src/HotReload.luau src/HotReloadSpec.luau
git commit -m "feat(reload): HotReload pure helpers — newLifecycle + resolvePath (Rojo path -> instance) + spec

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Extract `Main.luau` + lifecycle-aware `DevBridge` + bootstrap calls `Main.run`

**Files:** Create `src/Main.luau`; Modify `src/DevBridge.luau`; Modify `src/init.server.luau`.

This refactor keeps the plugin fully working (no reload yet): the bootstrap creates the toolbar/widget and delegates everything else to `Main.run`, whose dev-bridge loop is now lifecycle-aware.

- [ ] **Step 1: Make `DevBridge.start` lifecycle-aware (`src/DevBridge.luau`)**

The CURRENT `DevBridge.start` is:

```lua
-- Start the bridge. No-op unless EDIT mode AND config.devBridge. Localhost-only, plugin-only.
function DevBridge.start(deps: any)
	if not RunService:IsEdit() then
		return
	end
	if not deps.config:getDevBridge() then
		return
	end
	task.spawn(function()
		print("[StudioAgent] dev bridge active (sidecar " .. sidecarUrl(deps) .. ")")
		while true do
			pcall(tick, deps)
			task.wait(deps.config:getDevBridgePollInterval())
		end
	end)
end
```

Replace it with (adds a `lifecycle` param; the loop exits when a reload cancels the generation):

```lua
-- Start the bridge. No-op unless EDIT mode AND config.devBridge. Localhost-only, plugin-only. The loop
-- belongs to a generation: it checks `lifecycle.cancelled` each tick and exits when a hot-reload swaps in
-- a new generation, so reloads never leave a second loop polling.
function DevBridge.start(deps: any, lifecycle: any)
	if not RunService:IsEdit() then
		return
	end
	if not deps.config:getDevBridge() then
		return
	end
	task.spawn(function()
		print("[StudioAgent] dev bridge active (sidecar " .. sidecarUrl(deps) .. ")")
		while not lifecycle.cancelled do
			pcall(tick, deps)
			task.wait(deps.config:getDevBridgePollInterval())
		end
		print("[StudioAgent] dev bridge loop stopped (generation reloaded)")
	end)
end
```

- [ ] **Step 2: Create `src/Main.luau`**

```lua
--!strict
-- Main: the RELOADABLE plugin entry. Everything the bootstrap (init.server) does AFTER creating the
-- persistent toolbar/widget lives here, so a hot-reload swaps it wholesale. Main.run(ctx) builds the
-- deps, wires the relay, starts the (lifecycle-aware) dev bridge loop, mounts the UI, wires the button/
-- widget connections, and returns the generation's Lifecycle (the bootstrap cancels it on the next
-- reload). Requires its siblings via script.Parent.X so the clone's relative requires resolve.

local Widget = require(script.Parent.UI.Widget)
local Config = require(script.Parent.Config)
local Anthropic = require(script.Parent.Anthropic)
local AgentLoop = require(script.Parent.AgentLoop)
local SystemPrompt = require(script.Parent.SystemPrompt)
local Conversation = require(script.Parent.Conversation)
local Sessions = require(script.Parent.Sessions)
local TaskList = require(script.Parent.TaskList)
local Memory = require(script.Parent.Memory)
local Learnings = require(script.Parent.Learnings)
local SkillStore = require(script.Parent.SkillStore)
local RubricStore = require(script.Parent.RubricStore)
local CameraRig = require(script.Parent.CameraRig)
local Relay = require(script.Parent.Relay)
local DevBridge = require(script.Parent.DevBridge)
local HotReload = require(script.Parent.HotReload)

local Main = {}

export type Ctx = {
	plugin: Plugin,
	toolbar: PluginToolbar,
	button: PluginToolbarButton,
	widget: DockWidgetPluginGui,
}

-- Build a fresh generation: deps, relay, bridge loop, UI mount, connections. Returns its Lifecycle.
function Main.run(ctx: Ctx): HotReload.Lifecycle
	local plugin = ctx.plugin
	local widget = ctx.widget
	local button = ctx.button
	local lifecycle = HotReload.newLifecycle()

	-- Best-effort: enable runtime loadstring (run_luau) during a playtest (property absent in some
	-- Studio versions; the pcall swallows that).
	pcall(function()
		game:GetService("ServerScriptService").LoadStringEnabled = true
	end)

	local config = Config.new(plugin)
	local anthropic = Anthropic.new(config)
	local deps = {
		config = config,
		anthropic = anthropic,
		agentLoop = AgentLoop,
		systemPrompt = SystemPrompt.build(),
		conversation = Conversation.new(),
		sessions = Sessions.new(plugin),
		taskList = TaskList.new(),
		memory = Memory.new(plugin),
		learnings = Learnings.new(plugin),
		skills = SkillStore.new(plugin),
		rubrics = RubricStore.new(),
		cameraRig = CameraRig.new(config),
	}

	-- Client-view relay (edit: none; serverplay: host; clientplay: relay-aware anthropic).
	local relayMode = Relay.mode()
	if relayMode == "serverplay" then
		Relay.startHost(deps)
	elseif relayMode == "clientplay" then
		local relayClient = Relay.newClient()
		if relayClient ~= nil then
			deps.relay = relayClient
			deps.anthropic = Relay.wrapAnthropic(relayClient)
		end
	end

	DevBridge.start(deps, lifecycle)

	-- Mount the panel fresh this generation (clear any stale content first), and re-mount if Studio
	-- clears the widget on an edit<->play transition.
	local function ensureMounted()
		if widget:FindFirstChild("StudioAgentRoot") == nil then
			Widget.mount(widget, deps)
		end
	end
	local existingRoot = widget:FindFirstChild("StudioAgentRoot")
	if existingRoot ~= nil then
		existingRoot:Destroy()
	end
	ensureMounted()
	lifecycle:add(widget.ChildRemoved:Connect(function()
		task.defer(ensureMounted)
	end))

	lifecycle:add(button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
		button:SetActive(widget.Enabled)
	end))
	lifecycle:add(widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end))
	button:SetActive(widget.Enabled)

	print("[StudioAgent] Main generation running (hot-reloadable)")
	return lifecycle
end

return Main
```

- [ ] **Step 3: Shrink `src/init.server.luau` to delegate to `Main.run` (no reload yet)**

Replace the ENTIRE contents of `src/init.server.luau` with:

```lua
--!strict
-- StudioAgent bootstrap. Creates the persistent toolbar + dock widget (these survive hot-reloads —
-- Studio dedupes them by name/id), then runs the reloadable Main. (Task 5 adds the hot-reload
-- supervisor loop; until then this is a plain refactor that behaves exactly like before.)

local Main = require(script.Main)

local toolbar = plugin:CreateToolbar("Claude Agent")
local button =
	toolbar:CreateButton("StudioAgentToggle", "Open the Claude Agent panel", "", "Claude")
button.ClickableWhenViewportHidden = true

local info =
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 480, 260, 320)
local widget = plugin:CreateDockWidgetPluginGuiAsync("StudioAgentWidget", info)
widget.Title = "Claude Agent"

Main.run({ plugin = plugin, toolbar = toolbar, button = button, widget = widget })

print("[StudioAgent] bootstrap loaded")
```

- [ ] **Step 4: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. Watch for: `Main` requiring a sibling that doesn't exist via `script.Parent.X` (every name must match a real `src/X.luau` module — they do). The refactor is behavior-preserving; it's live-verified at Task 6.

- [ ] **Step 5: Commit**

```bash
git add src/Main.luau src/DevBridge.luau src/init.server.luau
git commit -m "refactor(plugin): split bootstrap (init.server) from a reloadable Main + lifecycle-aware DevBridge loop

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `HotReload.reload` + the supervisor loop + the final bootstrap

**Files:** Modify `src/HotReload.luau`; Modify `src/init.server.luau`.

- [ ] **Step 1: Add the impure `reload` + `startSupervisor` to `src/HotReload.luau`**

At the TOP of `src/HotReload.luau`, add the two service requires right after the header comment (before `local HotReload = {}`):

```lua
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
```

Then add the following functions just BEFORE the final `return HotReload`:

```lua
-- ---- impure (clone + require + swap; the poll loop) — live-verified ----

local function httpGetJson(url: string): (any?, string?)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if not ok then
		return nil, tostring(res)
	end
	local r = res :: any
	if not r.Success then
		return nil, "HTTP " .. tostring(r.StatusCode)
	end
	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not okDecode then
		return nil, "bad json"
	end
	return payload, nil
end

local function httpPostJson(url: string, body: any)
	pcall(function()
		HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
		})
	end)
end

-- Sort source entries so a folder's init.luau is applied BEFORE its leaf siblings — a brand-new
-- folder-module then becomes a ModuleScript before a leaf would create it as a Folder.
local function sortedEntries(sources: { [string]: string }): { { path: string, source: string } }
	local entries: { { path: string, source: string } } = {}
	for path, source in sources do
		table.insert(entries, { path = path, source = source })
	end
	table.sort(entries, function(a, b)
		local ai = if string.find(a.path, "init%.luau$") ~= nil then 0 else 1
		local bi = if string.find(b.path, "init%.luau$") ~= nil then 0 else 1
		if ai ~= bi then
			return ai < bi
		end
		return a.path < b.path
	end)
	return entries
end

-- Clone the bootstrap's module tree into a fresh container, write the synced source onto the clones
-- (creating instances for new paths; skipping the bootstrap), require the fresh Main, and — on success —
-- cancel the old generation and run the new one. On ANY failure the new clone is discarded and the
-- caller's old generation is left intact; the stable supervisor (which calls this) survives regardless,
-- so a fixed reload always recovers. Returns (ok, err).
function HotReload.reload(
	pluginScript: Instance,
	runtime: any,
	ctx: any,
	sources: { [string]: string }
): (boolean, string?)
	local container = Instance.new("Folder")
	container.Name = "StudioAgentReload"
	for _, child in pluginScript:GetChildren() do
		child:Clone().Parent = container
	end
	for _, e in sortedEntries(sources) do
		local parent, childName = HotReload.resolvePath(container, e.path)
		if parent ~= nil and childName ~= nil then
			local target = parent:FindFirstChild(childName)
			if target == nil then
				local ms = Instance.new("ModuleScript")
				ms.Name = childName
				ms.Parent = parent
				target = ms
			end
			pcall(function()
				(target :: any).Source = e.source
			end)
		end
	end

	local mainModule = container:FindFirstChild("Main")
	if mainModule == nil or not mainModule:IsA("ModuleScript") then
		container:Destroy()
		return false, "reload: no Main ModuleScript in the synced source"
	end
	local okRequire, fresh = pcall(require, mainModule :: ModuleScript)
	if not okRequire then
		container:Destroy()
		return false, "reload: Main require error — " .. tostring(fresh)
	end
	if type(fresh) ~= "table" or type((fresh :: any).run) ~= "function" then
		container:Destroy()
		return false, "reload: fresh Main has no run()"
	end

	-- Tear down the old generation, then run the new one. (require already caught load-time errors; if
	-- Main.run itself throws, the old loop is down but the stable supervisor recovers on the next reload.)
	if runtime.lifecycle ~= nil then
		pcall(function()
			runtime.lifecycle:cancel()
		end)
	end
	local okRun, result = pcall(function()
		return (fresh :: any).run(ctx)
	end)
	if not okRun then
		container:Destroy()
		return false, "reload: Main.run error — " .. tostring(result)
	end

	local oldContainer = runtime.container
	runtime.container = container
	runtime.lifecycle = result
	if oldContainer ~= nil then
		pcall(function()
			oldContainer:Destroy()
		end)
	end
	return true, nil
end

-- The STABLE supervisor loop (lives in the bootstrap generation, never cancelled). Polls /reload/pending;
-- on a request, reloads and posts the outcome. EDIT-only. `config` is a bootstrap-owned Config (stable),
-- not a generation's deps. `pluginScript` is the bootstrap Script (its children are the module tree).
function HotReload.startSupervisor(pluginScript: Instance, config: any, runtime: any, ctx: any)
	if not RunService:IsEdit() then
		return
	end
	task.spawn(function()
		local base = config:getSidecarUrl()
		print("[StudioAgent] hot-reload supervisor active (sidecar " .. base .. ")")
		while true do
			local pending = httpGetJson(base .. "/reload/pending")
			if
				type(pending) == "table"
				and (pending :: any).requested == true
				and type((pending :: any).sources) == "table"
			then
				local p = pending :: any
				local ok, err = HotReload.reload(pluginScript, runtime, ctx, p.sources)
				httpPostJson(base .. "/reload/result", { id = p.id, ok = ok, error = err })
				print("[StudioAgent] hot-reload " .. (if ok then "OK" else "FAILED — " .. tostring(err)))
			end
			task.wait(config:getDevBridgePollInterval())
		end
	end)
end
```

- [ ] **Step 2: Finalize the bootstrap (`src/init.server.luau`) — add the supervisor + runtime**

Replace the ENTIRE contents of `src/init.server.luau` with:

```lua
--!strict
-- StudioAgent bootstrap (STABLE — the only file that needs a Studio restart when changed; kept tiny).
-- Creates the persistent toolbar + dock widget (Studio dedupes them by name/id, so they survive hot-
-- reloads), runs generation 1 of the reloadable Main, and starts the hot-reload supervisor: a `reload`
-- from the shell makes the sidecar hand over the current src/, and HotReload swaps in fresh code with NO
-- restart. See docs/superpowers/specs/2026-06-26-dev-bridge-hot-reload-design.md.

local Main = require(script.Main)
local HotReload = require(script.HotReload)
local Config = require(script.Config)

local toolbar = plugin:CreateToolbar("Claude Agent")
local button =
	toolbar:CreateButton("StudioAgentToggle", "Open the Claude Agent panel", "", "Claude")
button.ClickableWhenViewportHidden = true

local info =
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 480, 260, 320)
local widget = plugin:CreateDockWidgetPluginGuiAsync("StudioAgentWidget", info)
widget.Title = "Claude Agent"

local ctx = { plugin = plugin, toolbar = toolbar, button = button, widget = widget }
local runtime = { lifecycle = nil :: any, container = nil :: any }

-- Generation 1: run the real Main directly (its source is already current; no clone needed).
runtime.lifecycle = Main.run(ctx)

-- Hot-reload supervisor (stable; survives a failed reload so a fixed reload recovers).
HotReload.startSupervisor(script, Config.new(plugin), runtime, ctx)

print("[StudioAgent] bootstrap loaded (hot-reload supervisor active)")
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. Watch for: selene flagging `runtime.lifecycle = nil :: any` (the `:: any` cast keeps it typed) or an unused local — fix without suppressing.

- [ ] **Step 4: Commit**

```bash
git add src/HotReload.luau src/init.server.luau
git commit -m "feat(reload): HotReload.reload (clone+resource+require+swap) + supervisor loop + wire the bootstrap

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Build + the ONE enabling restart + live proof

**Files:** none (live verification + HANDOFF).

> Gate to enter: Tasks 1–5 changed plugin code → run `.\build.ps1`. The sidecar `server.py` changed (Task 1) → **restart the sidecar** (`Stop-Process` the python on :8389, then `Start-Process py -ArgumentList server.py -WorkingDirectory sidecar`) so the new `/reload*` routes exist; the sidecar MUST be run from SOURCE (not the frozen exe) for `read_src_sources()` to find `src/`. Then **ask the USER for the ONE enabling Studio restart** (the last one — it loads the new bootstrap). Studio focused. Drive via `scripts/studio-agent.ps1`.

- [ ] **Step 1: Run the Python suites + the Luau specs**

Run:
```
python sidecar/test_bridge.py ; python sidecar/test_server.py
& scripts/studio-agent.ps1 luau 'return "HotReload=" .. tostring(require(script.Parent.HotReloadSpec).run()) .. " Anim=" .. tostring(require(script.Parent.AnimationClipSpec).run()) .. " Relay=" .. tostring(require(script.Parent.RelaySpec).run().passed)'
```
Expected: Python `7/7` + `1/1`; Luau `HotReload=true Anim=true Relay=true` (HotReloadSpec 8/8). If `HotReload` is false, a resolvePath/lifecycle case failed — fix and rebuild.

- [ ] **Step 2: Confirm the plugin still works post-refactor (a normal tool call)**

Run: `& scripts/studio-agent.ps1 tool get_tree '{"path":"Workspace","depth":1}'` (or any read tool).
Expected: a normal result — proving the bootstrap→Main refactor + the lifecycle-aware bridge loop run exactly like before.

- [ ] **Step 3: The hot-reload proof — change a tool string, reload, confirm (NO restart)**

Pick a harmless, visible tool string. In `src/Tools/Item.luau`, the `make_tool` OK message contains `"make_tool OK: '%s' at %s"`. Append a marker, e.g. change it to `"make_tool OK [reload-proof]: '%s' at %s"`. Save. Then:
```
& scripts/studio-agent.ps1 reload
```
Expected: `reload ok`. Now exercise the changed tool:
```
& scripts/studio-agent.ps1 luau 'local m = Instance.new("Part") m.Name = "ReloadProbe" m.Parent = workspace return m:GetFullName()'
& scripts/studio-agent.ps1 tool make_tool '{"target":"Workspace.ReloadProbe","name":"ReloadProbe"}'
```
Expected: the result now contains `[reload-proof]` — **the new code ran with no Studio restart**. Then REVERT the marker in `src/Tools/Item.luau` and `& scripts/studio-agent.ps1 reload` again; confirm the message is back to normal AND that the tool still returns exactly ONE result (proving the old loop was torn down — no duplicate generation). Clean up the `ReloadProbe`.

- [ ] **Step 4: Stress the failure-safety (a broken reload recovers)**

Temporarily introduce a syntax error in a leaf module (e.g. add a stray `)` at the top of `src/Tools/Mesh.luau`), then `& scripts/studio-agent.ps1 reload`.
Expected: `reload FAILED: ...` (the require error). Confirm the plugin STILL responds (`& scripts/studio-agent.ps1 tool get_tree '{"path":"Workspace","depth":1}'` still works — the old generation survived). Then FIX the syntax error and `reload` again → `reload ok`, tools work. (This proves a bad reload never bricks the plugin.)

- [ ] **Step 5: HANDOFF + memory + commit**

Confirm `selene src` 0/0 and that `src/Tools/Item.luau` / `src/Tools/Mesh.luau` are back to their committed state (the proof edits reverted). Update `HANDOFF.md` with a START-HERE block (hot-reload SHIPPED + bridge-verified: `studio-agent.ps1 reload` swaps in fresh code with no Studio restart; the bootstrap/HotReload are the only restart-requiring files; the sidecar must run from source). Note in memory that the dev loop no longer needs manual restarts (a reusable workflow fact). Commit:

```bash
git add HANDOFF.md docs/superpowers/plans/2026-06-26-dev-bridge-hot-reload.md
git commit -m "docs: dev-bridge hot-reload shipped + bridge-verified (no more manual Studio restarts)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> After this lands, return to roadmap #2 (the swing-not-firing + grip) and fix it using `reload` instead of restarts — confirm at runtime that keeping the carrier chain at `Pose.Weight = 0` plays AND keeps the head level.

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1a bootstrap/Main split → Task 4 (`Main.luau`, thin `init.server`) + Task 5 (final bootstrap); §1b lifecycle → Task 3 (`newLifecycle`) + Task 4 (DevBridge checks `cancelled`, Main registers connections) + Task 5 (reload cancels old); §1c supervisor + sidecar channel → Task 1 (endpoints) + Task 2 (`reload` cmd) + Task 5 (`startSupervisor`); §1d reload engine + `resolvePath` → Task 3 (`resolvePath`) + Task 5 (`reload`); §1e gen-1 → Task 5 bootstrap; §2 files → all tasks; §3 data flow → Task 5 `reload`/`startSupervisor`; §4 error handling (bad code keeps old gen; reload-mid-command via separate loops; new files via create-in-`resolvePath`; bootstrap/HotReload stable; edit/localhost-only; transient state) → Task 5 `reload` (pcall guards) + Task 3 (`resolvePath` creates) + Tasks 4/5 (`IsEdit` guards); §5 testing → Task 1 (Python) + Task 3 (spec) + Task 6 (live); §6 scope (auto-watch/self-reload/conversation-persistence/play-mode all OUT) correctly absent.
- **Type/name consistency:** `HotReload.newLifecycle`/`resolvePath`/`reload`/`startSupervisor` are defined in Tasks 3+5 and consumed by `Main.run` (Task 4) + the bootstrap (Task 5) with identical signatures; `Lifecycle` type (Task 3) is the return of `Main.run` (Task 4) and the field `runtime.lifecycle` (Task 5); `DevBridge.start(deps, lifecycle)` (Task 4) is called by `Main.run` (Task 4); the sidecar routes `/reload`, `/reload/pending`, `/reload/result` (Task 1) match `studio-agent.ps1 reload` (Task 2) and `startSupervisor` (Task 5); `read_src_sources` keys (Rojo-relative posix paths) match `resolvePath`'s input contract; the `runtime = { lifecycle, container }` shape is written by the bootstrap (Task 5) and mutated by `reload` (Task 5).
- **Failure-safety:** every `reload` exit destroys the new container or swaps cleanly; `require`/`run` are pcall-wrapped; the supervisor lives outside any generation's lifecycle, so it always survives to accept a recovery reload. The bridge loop and the supervisor poll DIFFERENT endpoints (`/agent/pending` vs `/reload/pending`) so they never consume each other's work.
