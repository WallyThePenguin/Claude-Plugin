# Play-mode Dev Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start, drive, observe, and stop a Studio playtest entirely from the shell (no F5, no desktop control) via `StudioTestService`, so the agent self-verifies runtime behavior — closing #2's runtime gate.

**Architecture:** A new sidecar `/play` channel (mirrors `/agent`). The edit-side `PlayBridge` loop handles `play start` by `task.spawn`-ing `StudioTestService:ExecutePlayModeAsync()` (a `playing` flag keeps it from competing with the in-test loop). Inside the test the `PlayBridge` loop runs `eval`/`capture`/`act`/`stop` (EndTest). The client-vs-server polling question is resolved by a live probe (Task 4) before the driving (Task 5) is built. Everything edit/play-side lives in the reloadable `Main`, so it hot-reloads.

**Tech Stack:** Luau (`--!strict`), `StudioTestService` (PluginSecurity — verified live), `Relay` mode detection, `CaptureCore` + the sidecar `/captures` disk-read, the Python stdlib sidecar, `scripts/studio-agent.ps1`, the hot-reload (iterate with no restart), Rojo, `selene`/`stylua`.

---

## File Structure

- **Modify `sidecar/bridge.py`** — `Store` gains a `/play` command slot + result map.
- **Modify `sidecar/server.py`** — `POST /play`, `GET /play/pending`, `POST /play/result`, `GET /play/result?id=N`.
- **Modify `sidecar/test_bridge.py`** — `/play` Store tests.
- **Modify `scripts/studio-agent.ps1`** — a `play` subcommand.
- **Create `src/PlayBridge.luau`** — edit-side start handler + in-test loop + `act`-verb expansion (pure) + dispatch.
- **Create `src/PlayBridgeSpec.luau`** — pure tests (`act`-verb expansion, command classification).
- **Modify `src/Main.luau`** — `PlayBridge.start(deps, lifecycle)` in every generation (it branches on `Relay.mode()`).
- **Modify `src/SystemPrompt.luau`** — a one-line note that the agent can self-playtest.

**Testing notes:** Python — `python sidecar/test_bridge.py`. Luau spec — in-Studio / via the bridge (`& scripts/studio-agent.ps1 luau 'return tostring(require(script.Parent.PlayBridgeSpec).run())'`). Static gate per task: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (0/0). **Plugin code changes now apply via `& scripts/studio-agent.ps1 reload` — NO Studio restart** (the hot-reload supervisor is live). A bootstrap/HotReload change would need a restart, but this plan touches neither.

---

### Task 1: Sidecar `/play` channel + tests

**Files:** Modify `sidecar/bridge.py`; Modify `sidecar/server.py`; Modify `sidecar/test_bridge.py`.

- [ ] **Step 1: Write failing Store tests.** In `sidecar/test_bridge.py`, add before the `if __name__` runner:

```python
def test_play_submit_take_clears():
    s = Store()
    pid = s.play_submit({"cmd": "start"})
    assert pid == 1
    cmd = s.play_take_pending()
    assert cmd["id"] == 1 and cmd["cmd"] == "start"
    assert s.play_take_pending() is None


def test_play_result_roundtrip():
    s = Store()
    s.play_put_result(5, {"ok": True, "result": "x"})
    assert s.play_get_result(5) == {"ok": True, "result": "x"}
    assert s.play_get_result(6) is None
```

- [ ] **Step 2: Run → fail.** `python sidecar/test_bridge.py` → the two new tests crash (no `play_submit`).

- [ ] **Step 3: Add the `/play` channel to `Store` (`sidecar/bridge.py`).** In `__init__`, after the `_reload_results` line:

```python
        self._play = None       # the one queued play command, or None
        self._play_counter = 0
        self._play_results = {}  # play command id -> result dict
```

Add these methods (after `get_reload_result`):

```python
    def play_submit(self, command: dict) -> int:
        """Queue a play command (its own single-slot channel, separate from /agent). Returns its id."""
        with self._lock:
            self._play_counter += 1
            cmd = dict(command)
            cmd["id"] = self._play_counter
            self._play = cmd
            return self._play_counter

    def play_take_pending(self):
        with self._lock:
            cmd = self._play
            self._play = None
            return cmd

    def play_put_result(self, command_id: int, result: dict):
        with self._lock:
            self._play_results[int(command_id)] = result

    def play_get_result(self, command_id: int):
        with self._lock:
            return self._play_results.get(int(command_id))
```

- [ ] **Step 4: Run → pass.** `python sidecar/test_bridge.py` → `9/9 passed`.

- [ ] **Step 5: Add the `/play` endpoints (`sidecar/server.py`).** In `do_POST`, before the final 404:

```python
        if parsed.path == "/play":
            return self._json(200, {"id": STORE.play_submit(body)})
        if parsed.path == "/play/result":
            cid = body.get("id")
            if not isinstance(cid, int):
                return self._json(400, {"error": "play result needs an integer id"})
            STORE.play_put_result(cid, body)
            return self._json(200, {"ok": True})
```

In `do_GET`, before the final 404:

```python
        if parsed.path == "/play/pending":
            return self._json(200, STORE.play_take_pending() or {})
        if parsed.path == "/play/result":
            try:
                cid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            res = STORE.play_get_result(cid)
            return self._json(200, res if res is not None else {"status": "pending"})
```

Append to the `server.py` header docstring's route list:

```
POST /play {"cmd":...}                                    -> {"id":N}  (a playtest command)
GET  /play/pending                                        -> the queued play command (and clears it) or {}
POST /play/result {"id":N, ...}                           -> {"ok":true}
GET  /play/result?id=N                                    -> the play command result, or {"status":"pending"}
```

Update the `bridge.py` module docstring to mention the play channel (append `, plus a single-slot playtest command channel + result map`).

- [ ] **Step 6: Commit.**

```bash
git add sidecar/bridge.py sidecar/server.py sidecar/test_bridge.py
git commit -m "feat(sidecar): /play channel (POST /play + /play/pending + /play/result) + Store tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `studio-agent.ps1 play` subcommand

**Files:** Modify `scripts/studio-agent.ps1`.

- [ ] **Step 1: Add the `play` branch** (after the `reload` branch, before `capture`):

```powershell
    "play" {
        $payload = @{ cmd = $Arg1 }
        if ($Arg2) { $payload.arg = $Arg2 }
        $r = Invoke-RestMethod -Method Post -Uri "$base/play" -Body ($payload | ConvertTo-Json -Compress) -ContentType "application/json"
        $id = $r.id
        $deadline = (Get-Date).AddSeconds(150)
        $res = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $res = Invoke-RestMethod -Method Get -Uri "$base/play/result?id=$id"
            if ($res.PSObject.Properties.Name -contains "ok") { break }
        }
        if ($res -and ($res.PSObject.Properties.Name -contains "ok")) {
            "ok=$($res.ok)"; $res.result; if ($res.error) { "ERROR: $($res.error)" }
        } else { "play: timed out (id=$id) — is a test running / the PlayBridge polling?" }
    }
```

- [ ] **Step 2: Usage + default.** Add a usage line under the `reload` one:

```powershell
#   .\studio-agent.ps1 play start|stop|eval|capture|act <arg>   drive a self-running playtest
```

Update the `default` branch hint to include `play`: `(use tool|luau|prompt|logs|reload|play|capture)`.

- [ ] **Step 3: Parse check.** `& scripts/studio-agent.ps1 logs` runs without a parse error (the `play` path is exercised live in Task 4).

- [ ] **Step 4: Commit.**

```bash
git add scripts/studio-agent.ps1
git commit -m "feat(bridge): studio-agent.ps1 play subcommand (POST /play + poll the result)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `PlayBridge` skeleton + StudioTestService entry + the probe harness

**Files:** Create `src/PlayBridge.luau`; Create `src/PlayBridgeSpec.luau`; Modify `src/Main.luau`.

This ships: the pure `act`-verb expansion (tested), the edit-side `start` handler (`ExecutePlayModeAsync` + `playing` flag), and an in-test loop that — for the FIRST run — probes the unknowns (mode, can-it-poll, capture) and auto-`EndTest`s, so Task 4 can resolve §1c/§2 of the spec with zero risk of hanging the editor.

- [ ] **Step 1: Create `src/PlayBridge.luau`:**

```lua
--!strict
-- PlayBridge: drive a Studio PLAYTEST from the shell over the sidecar /play channel (no F5). The EDIT
-- generation handles `start` (task.spawn StudioTestService:ExecutePlayModeAsync; a `playing` flag keeps it
-- from grabbing the in-test loop's commands). The serverplay/clientplay generation runs the in-test loop:
-- eval/capture/act/stop, with an idle auto-EndTest so a test can never strand the editor. Lifecycle-aware
-- (hot-reloads with Main). See docs/superpowers/specs/2026-06-26-play-mode-bridge-design.md.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Relay = require(script.Parent.Relay)

local PlayBridge = {}

-- ---- pure (unit-tested) ----

-- Expand an `act` verb (+ optional arg) into a Luau snippet run in the play DM. Drives the local
-- character via the Humanoid/Tool API. Unknown verb -> nil. PURE.
function PlayBridge.actSnippet(verb: string, _arg: string?): string?
	if verb == "equip" then
		return [[
local p = game:GetService("Players").LocalPlayer
local char = p.Character
local hum = char and char:FindFirstChildOfClass("Humanoid")
local tool = p:FindFirstChild("Backpack") and p.Backpack:FindFirstChildOfClass("Tool")
if hum and tool then hum:EquipTool(tool) return "equipped " .. tool.Name end
return "no humanoid/tool to equip"]]
	elseif verb == "walk" then
		return [[
local p = game:GetService("Players").LocalPlayer
local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
if hum then hum:Move(p.Character.PrimaryPart and p.Character.PrimaryPart.CFrame.LookVector or Vector3.new(0,0,-1), false) return "walking" end
return "no humanoid"]]
	elseif verb == "stop" then
		return [[
local p = game:GetService("Players").LocalPlayer
local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
if hum then hum:Move(Vector3.new(0,0,0), false) return "stopped" end
return "no humanoid"]]
	elseif verb == "activate" then
		return [[
local p = game:GetService("Players").LocalPlayer
local char = p.Character
local tool = char and char:FindFirstChildOfClass("Tool")
if tool then tool:Activate() return "activated " .. tool.Name end
return "no equipped tool"]]
	end
	return nil
end

-- ---- impure HTTP (sidecar) ----

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
	local okD, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not okD then
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

-- ---- edit-side: handle `start` ----

local playing = false

function PlayBridge.startEditLoop(deps: any, lifecycle: any)
	if not RunService:IsEdit() then
		return
	end
	local base = deps.config:getSidecarUrl()
	task.spawn(function()
		while not lifecycle.cancelled do
			if not playing then
				local cmd = httpGetJson(base .. "/play/pending")
				if type(cmd) == "table" and (cmd :: any).cmd ~= nil then
					local c = cmd :: any
					if c.cmd == "start" then
						playing = true
						task.spawn(function()
							local StudioTestService = game:GetService("StudioTestService")
							local okRun, result = pcall(function()
								return (StudioTestService :: any):ExecutePlayModeAsync({ studioAgentPlay = true })
							end)
							playing = false
							httpPostJson(base .. "/play/result", {
								id = c.id,
								ok = okRun,
								result = "test ended: " .. tostring(result),
							})
						end)
						httpPostJson(
							base .. "/play/result",
							{ id = c.id, ok = true, result = "play starting (ExecutePlayModeAsync)" }
						)
					else
						httpPostJson(
							base .. "/play/result",
							{ id = c.id, ok = false, error = "no active test — run `play start` first" }
						)
					end
				end
			end
			task.wait(deps.config:getDevBridgePollInterval())
		end
	end)
end

-- ---- in-test: poll + dispatch (Task 5 fills eval/capture/act; this skeleton PROBES then EndTests) ----

function PlayBridge.startTestLoop(deps: any, lifecycle: any, mode: string)
	local base = deps.config:getSidecarUrl()
	task.spawn(function()
		-- PROBE (resolves §1c/§2): report mode + whether THIS copy can reach the sidecar.
		local probeOk = httpGetJson(base .. "/play/pending") ~= nil
		httpPostJson(base .. "/logs", {
			lines = {
				{
					kind = "play-probe",
					text = ("[PlayBridge] mode=%s canPoll=%s server=%s client=%s"):format(
						mode,
						tostring(probeOk),
						tostring(RunService:IsServer()),
						tostring(RunService:IsClient())
					),
				},
			},
		})
		-- Idle auto-EndTest: end the test after ~30s with no command, so it never strands the editor.
		local deadline = os.clock() + 30
		while not lifecycle.cancelled and os.clock() < deadline do
			-- Task 5 replaces this body with the real eval/capture/act/stop dispatch.
			task.wait(0.5)
		end
		if mode == "serverplay" then
			pcall(function()
				(game:GetService("StudioTestService") :: any):EndTest("idle-timeout")
			end)
		end
	end)
end

function PlayBridge.start(deps: any, lifecycle: any)
	local mode = Relay.mode()
	if mode == "edit" then
		PlayBridge.startEditLoop(deps, lifecycle)
	elseif mode == "serverplay" or mode == "clientplay" then
		PlayBridge.startTestLoop(deps, lifecycle, mode)
	end
end

return PlayBridge
```

- [ ] **Step 2: Create `src/PlayBridgeSpec.luau`** (pure `actSnippet` tests):

```lua
--!strict
-- PlayBridgeSpec: pure tests for PlayBridge.actSnippet (the act-verb -> Luau-snippet expansion). No
-- sidecar/play. Run: luau 'return tostring(require(script.Parent.PlayBridgeSpec).run())'.

local PlayBridge = require(script.Parent.PlayBridge)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("actSnippet: known verbs return a non-empty snippet", function()
		for _, v in { "equip", "walk", "stop", "activate" } do
			local s = PlayBridge.actSnippet(v, nil)
			if type(s) ~= "string" or s == "" then
				return false, v .. " returned no snippet"
			end
		end
		return true
	end)

	add("actSnippet: equip references EquipTool, activate references Activate", function()
		local e = PlayBridge.actSnippet("equip", nil) :: string
		local a = PlayBridge.actSnippet("activate", nil) :: string
		if string.find(e, "EquipTool", 1, true) == nil then
			return false, "equip snippet missing EquipTool"
		end
		if string.find(a, "Activate", 1, true) == nil then
			return false, "activate snippet missing Activate"
		end
		return true
	end)

	add("actSnippet: an unknown verb returns nil", function()
		return PlayBridge.actSnippet("fly", nil) == nil, "unknown verb should be nil"
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
			print("[PlayBridgeSpec] PASS " .. c.name)
		else
			warn("[PlayBridgeSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[PlayBridgeSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Wire `PlayBridge.start` into `Main.run` (`src/Main.luau`).** Add the require near the other sibling requires: `local PlayBridge = require(script.Parent.PlayBridge)`. Then, right after the `DevBridge.start(deps, lifecycle)` line, add: `PlayBridge.start(deps, lifecycle)`. (Main.run runs in every generation — edit + serverplay + clientplay — so `PlayBridge.start` branches itself on `Relay.mode()`.)

- [ ] **Step 4: Static gate.** `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` → selene 0/0; rojo clean. (selene may flag the long `[[...]]` snippets — they're fine as string literals.)

- [ ] **Step 5: Commit.**

```bash
git add src/PlayBridge.luau src/PlayBridgeSpec.luau src/Main.luau
git commit -m "feat(play): PlayBridge skeleton — edit-side ExecutePlayModeAsync start + in-test probe loop + actSnippet + wire

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: LIVE verification (resolve the unknowns) — orchestrator-run

**Files:** none (live probes + findings recorded for Task 5).

> Apply Tasks 1–3 to the running plugin with `& scripts/studio-agent.ps1 reload` (NO restart). Restart the sidecar (Task 1 changed `server.py`): stop the python on :8389, `Start-Process py server.py -WorkingDirectory sidecar`. Run `python sidecar/test_bridge.py` (9/9) + `PlayBridgeSpec` via the bridge.

- [ ] **Step 1: Probe a test round-trip.** `& scripts/studio-agent.ps1 play start` → expect `play starting`. Wait ~3s, then `& scripts/studio-agent.ps1 logs` and read the `[PlayBridge] mode=… canPoll=… server=… client=…` line(s). Record: (a) which copy(ies) loaded (serverplay/clientplay/both/single), (b) which can poll the sidecar (`canPoll=true`). The test auto-EndTests after 30s (or `play stop` once Task 5 adds it). **If NO `[PlayBridge]` line appears**, the plugin did not load in the `ExecutePlayModeAsync` session — STOP and report; the fallback is to inject a poller script into the place at `start` instead of relying on the plugin loading.
- [ ] **Step 2: Confirm capture-in-play.** While a test runs (re-`play start`), trigger a capture from the in-test loop manually via the logs/probe (Task 5 wires `play capture`; here, confirm `CaptureService:CaptureScreenshot` in the play client writes a file the sidecar `/captures` returns — fetch `GET /captures?count=1`).
- [ ] **Step 3: Record findings** (in this plan or the HANDOFF): client-polls vs server-relay; single vs separate DMs; capture path OK. These drive Task 5's dispatch placement.

---

### Task 5: In-test dispatch (eval / capture / act / stop) — per Task 4 findings

**Files:** Modify `src/PlayBridge.luau` (replace the `startTestLoop` probe body with the real dispatch).

> Baseline = the polling copy (client if `canPoll`, else server) runs the loop; `stop` calls `EndTest` on the server copy. If Task 4 found the client CANNOT poll, the server polls and relays `capture`/`act` to a client handler over a `StudioAgentPlayRelay` RemoteEvent (mirror `Relay.startHost`/`newClient`). The exact split is filled from Task 4; the dispatch contract below is fixed.

- [ ] **Step 1: Replace `startTestLoop`'s body** with a poll loop that, per command:
  - `eval` → `Tools.dispatch("run_luau", { code = c.arg }, ctx)` (runs in the play DM), post `(content, isError)`.
  - `capture` → `CaptureCore.triggerCapture()` + `CaptureCore.settle(2)`; post `{ ok=true, result="captured" }` (the shell fetches `/captures`).
  - `act` → `local snip = PlayBridge.actSnippet(c.arg, …)`; if nil → error; else dispatch it as `run_luau`.
  - `stop` → `EndTest(...)` (server copy), post `{ ok=true, result="stopping" }`.
  - reset the idle deadline on each command; keep the 30s idle auto-`EndTest`.
  (Concrete code written during execution from the Task 4 findings — it's a mechanical fill of the dispatch switch + the role split; commit it then.)

- [ ] **Step 2: Static gate + reload + commit.** selene 0/0; `reload`; then a live `play eval`/`play act`/`play capture` round-trip works. Commit `feat(play): in-test eval/capture/act/stop dispatch`.

---

### Task 6: SystemPrompt note + the self-driven live gate (closes #2)

**Files:** Modify `src/SystemPrompt.luau`; none else (live gate + HANDOFF).

- [ ] **Step 1: SystemPrompt note.** In the "# Inspecting visually" or "# Animating" area, add one line: that the agent can self-playtest a build with `play start` / `play act equip|walk|activate` / `play capture` / `play stop` (Studio-solo; runtime gate). `reload` + selene 0/0 + commit.

- [ ] **Step 2: The self-driven #2 gate.** With the #2 sword in StarterPack: `play start` → `play capture` (in game) → `play act equip` + `play capture` (held pose, blade up) → `play act walk` + `play capture` (legs walk, **head level**, arm holds) → `play act activate` + `play capture` (the swing) → `play stop`. READ each capture. This is the first runtime gate the agent confirms with NO human Play press. If the head is level + it plays + blade up, **#2 is verified**.

- [ ] **Step 3: HANDOFF + memory + commit.** Record: the Play-mode bridge shipped (autonomous playtests via StudioTestService); #2 verified end-to-end by the agent; the Play-mode driving findings (DM topology, capture-in-play). Memory: a reusable fact that the agent can now self-playtest. Commit `docs: play-mode bridge shipped + #2 verified self-driven`.

---

## Self-Review notes (for the executor)

- **Spec coverage:** §0 StudioTestService → Task 3 (edit start) + Task 5 (stop); §1a entry/exit + `playing` flag + `/play` channel → Task 1 (channel) + Task 3 (`startEditLoop`); §1b in-test eval/capture/act/stop → Task 5 (+ `actSnippet` Task 3); §1c client/server split → Task 4 (verify) + Task 5 (implement per finding); §1d shell → Task 2; §2 the 3 build verifications → Task 4 (+ the Task 3 probe + auto-EndTest safety); §3 files → all tasks; §4 data flow → Tasks 3+5; §5 error handling (never-hang via idle auto-EndTest in Task 3/5; total dispatch in Task 5; already-playing/not-playing in Task 3's `startEditLoop`) ; §6 testing → Task 1 (Python) + Task 3 (spec) + Task 4/6 (live); §7 out-of-scope (multiplayer, rich VirtualInput, mid-test hot-reload) correctly absent.
- **Verification-gated honesty:** Task 5's exact role-split code is filled from Task 4's live findings (the one place the plan can't be 100% concrete upfront — the DM topology is a genuine unknown). The dispatch CONTRACT (eval/capture/act/stop semantics + `actSnippet`) is fixed in Task 3; only WHERE it runs (client vs server) is resolved by Task 4.
- **Type/name consistency:** `PlayBridge.start`/`startEditLoop`/`startTestLoop`/`actSnippet` are defined in Task 3 and consumed by `Main.run` (Task 3) + Task 5; the `/play` Store methods `play_submit`/`play_take_pending`/`play_put_result`/`play_get_result` (Task 1) match the server routes (Task 1) + the shell `play` subcommand (Task 2); the in-test loop uses `deps.config:getSidecarUrl()`/`getDevBridgePollInterval()` (existing Config getters); `CaptureCore.triggerCapture`/`settle` (existing).
- **Never-hang invariant:** every test path auto-`EndTest`s on a 30s idle, so a dropped shell, a crash, or a forgotten `stop` always returns Studio to edit.
