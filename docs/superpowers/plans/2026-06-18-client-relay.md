# Client-View Server Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the agent usable in the Play **client** view (no manual Server-view switch) by relaying its two server-only operations — the Anthropic HTTP send and the DataModel/HTTP/loop-spawning tool dispatches — to a `RemoteFunction` executor hosted by the play-session SERVER plugin copy.

**Architecture:** Accurate Play Solo runs separate per-context plugin copies (LIVE-VERIFIED 2026-06-18). The SERVER copy hosts a `RemoteFunction` (`StudioAgentRelay`) whose `OnServerInvoke` runs HTTP / tool dispatch on the authoritative server DataModel. The CLIENT copy (the panel the user sees in client view) keeps the loop + plugin-only state, and routes only those two choke points through `InvokeServer`; plugin-only tools (`update_tasks`/`remember`/`forget`/skills) run locally. The relay is plugin-only + ephemeral (created at play-start, gone on Stop → never saved), so it can never leak to a published game. If the RF isn't found, it falls back to today's "switch to the Server view" behavior.

**Tech Stack:** Luau (`--!strict`), Rojo, selene, stylua. No new deps. Static verification: `selene src` (0 errors) + `stylua --check src` + `rojo build` via `.\build.ps1`. Logic test: in-Studio `RelaySpec`. Live behavior: drive Studio (NEW Baseplate, hecate tunnel up).

**Verification reality (from HANDOFF):** Luau using Roblox APIs can't run here — each task is statically verified with `selene src` (0 errors) + `stylua --check src`; `RelaySpec` is run in Studio; live behavior is verified by driving Studio in the client view. **The `relay` param is optional and nil-safe at every site**, so each task builds clean independently (a half-wired tree just behaves like today).

---

## File Structure

**Create:**
- `src/Relay.luau` — the whole relay: `mode()` (context detection), `shouldRelayTool(name)`, `startHost(deps)` (server-copy RF + dispatcher), `newClient()` (client-copy RF finder + `http`/`tool`), `wrapAnthropic(client)` (a drop-in `anthropic` whose `:sendMessage` relays).
- `src/RelaySpec.luau` — in-Studio self-test for the pure surface (`mode` in edit, `shouldRelayTool` classification + completeness vs the registry, `wrapAnthropic` routing).

**Modify:**
- `src/AgentLoop.luau` — thread an optional `relay` through `send` → `runLoop`; branch the tool-dispatch site through `relay.tool` for relayed tools; `require` Relay.
- `src/UI/Widget.luau` — pass `deps.relay` as the new trailing arg to `deps.agentLoop.send(...)`.
- `src/init.server.luau` — per-copy wiring from `Relay.mode()` (start the host in serverplay; build the client + wrap `deps.anthropic` in clientplay).

---

## Task 1: `Relay.luau` + `RelaySpec.luau`

**Files:**
- Create: `src/Relay.luau`
- Create: `src/RelaySpec.luau`

- [ ] **Step 1: Implement `src/Relay.luau`**

```lua
--!strict
-- Relay: lets the agent work in the Play CLIENT view without switching to the Server view.
-- Accurate Play Solo runs SEPARATE per-context plugin copies (LIVE-VERIFIED 2026-06-18): a SERVER
-- copy whose in-session HttpService + Instance.new builds work, and a CLIENT copy that hosts the
-- panel the user sees in client view. A plugin in the CLIENT copy CAN call a server-created
-- RemoteFunction:InvokeServer and receive its return (proven). So:
--   * the SERVER copy hosts a RemoteFunction "StudioAgentRelay"; its OnServerInvoke runs the two
--     server-only operations on the authoritative server DM — the Anthropic HTTP send, and the
--     DataModel/HTTP/loop-spawning tool dispatches;
--   * the CLIENT copy's loop relays exactly those two through InvokeServer, and runs plugin-only
--     tools (update_tasks/remember/forget/skills) LOCALLY.
-- Plugin-only + ephemeral (created at play-start, discarded on Stop -> never saved), so it can never
-- leak to a published game. Falls back to today's "switch to the Server view" if the RF isn't found.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Relay = {}

-- The relay RemoteFunction name in ReplicatedStorage (replicates server->client during play).
local RELAY_RF_NAME = "StudioAgentRelay"
-- How long the client copy waits for the RF to replicate before falling back.
local WAIT_TIMEOUT = 10

-- Tools that touch ONLY plugin/panel state (no DataModel, no HTTP, no child loops) -> run LOCALLY in
-- the client copy. Everything else (DataModel/HTTP/dispatch tools) relays to the server copy.
local LOCAL_TOOLS: { [string]: boolean } = {
	update_tasks = true,
	remember = true,
	forget = true,
	use_skill = true,
	save_skill = true,
	delete_skill = true,
}

-- "edit" | "serverplay" | "clientplay" | "other". IsEdit() FIRST: edit reports IsServer=true AND
-- IsClient=true, so it must be classified before the play checks.
function Relay.mode(): string
	if RunService:IsEdit() then
		return "edit"
	end
	if RunService:IsRunning() and RunService:IsStudio() then
		if RunService:IsServer() and not RunService:IsClient() then
			return "serverplay"
		end
		if RunService:IsClient() and not RunService:IsServer() then
			return "clientplay"
		end
	end
	return "other"
end

-- A tool relays to the server unless it is plugin/panel-state-only.
function Relay.shouldRelayTool(name: string): boolean
	return not LOCAL_TOOLS[name]
end

-- SERVER play copy: create the relay RemoteFunction and set its dispatcher. Total (never throws);
-- returns the RF, or nil on failure. Runs fresh each play start (fresh play DM each time).
function Relay.startHost(deps: any): any?
	-- Lazy require (Tools is already loaded by init time; avoids any load-order surprise).
	local Tools = require(script.Parent.Tools)

	local ok, rf = pcall(function()
		local existing = ReplicatedStorage:FindFirstChild(RELAY_RF_NAME)
		if existing ~= nil and existing:IsA("RemoteFunction") then
			return existing
		end
		local r = Instance.new("RemoteFunction")
		r.Name = RELAY_RF_NAME
		r.Parent = ReplicatedStorage
		return r
	end)
	if not ok or rf == nil then
		return nil
	end

	-- Server-side tool context = the server copy's own config/anthropic. update_tasks/remember/forget/
	-- skills never relay, so no taskList/memory/skills here (relayed dispatch nil-guards them like the
	-- subagent children already do).
	local serverToolContext = { config = deps.config, anthropic = deps.anthropic }

	local remote = rf :: RemoteFunction
	remote.OnServerInvoke = function(_player, request)
		-- Total: a thrown handler returns a structured error instead of erroring InvokeServer.
		local ok2, result = pcall(function()
			if type(request) ~= "table" then
				return { kind = "error", message = "relay: malformed request" }
			end
			if request.kind == "http" then
				return { kind = "http", result = deps.anthropic:sendMessage(request.opts) }
			elseif request.kind == "tool" then
				local content, isError = Tools.dispatch(request.name, request.input, serverToolContext)
				return { kind = "tool", content = content, isError = isError }
			end
			return { kind = "error", message = "relay: unknown request kind " .. tostring(request.kind) }
		end)
		if ok2 then
			return result
		end
		return { kind = "error", message = "relay handler error: " .. tostring(result) }
	end

	return remote
end

-- CLIENT play copy: find the relay RF (waits up to WAIT_TIMEOUT for it to replicate). Returns a
-- client table with `http`/`tool` (dot-called, no self), or nil if the RF never appeared (caller then
-- leaves the real anthropic in place so the existing client-context error guides the user).
function Relay.newClient(): any?
	local rf = ReplicatedStorage:WaitForChild(RELAY_RF_NAME, WAIT_TIMEOUT)
	if rf == nil or not rf:IsA("RemoteFunction") then
		return nil
	end
	local remote = rf :: RemoteFunction
	local client = {}

	-- HTTP relay -> an Anthropic.Result. On any failure, a context-kind Result mirroring
	-- Anthropic.request's client-context error, so the loop degrades gracefully (never crashes).
	function client.http(opts: any): any
		local ok, res = pcall(function()
			return remote:InvokeServer({ kind = "http", opts = opts })
		end)
		if ok and type(res) == "table" and res.kind == "http" and type(res.result) == "table" then
			return res.result
		end
		return {
			ok = false,
			kind = "context",
			message = "relay unavailable — switch Studio to the Server view (Client/Server dropdown).",
		}
	end

	-- Tool relay -> (content, isError). On failure, an is_error string telling the user to switch.
	function client.tool(name: string, input: any): (any, boolean)
		local ok, res = pcall(function()
			return remote:InvokeServer({ kind = "tool", name = name, input = input })
		end)
		if ok and type(res) == "table" and res.kind == "tool" then
			return res.content, res.isError == true
		end
		return "relay unavailable — switch Studio to the Server view to run this.", true
	end

	return client
end

-- A relay-aware `anthropic` drop-in: Retry + Compactor only call `anthropic:sendMessage(opts)`, so we
-- only need sendMessage. It routes the call through the relay client's http(); the SERVER copy then
-- builds the body (model/max_tokens) and applies the empty-object {} encode fix.
function Relay.wrapAnthropic(client: any): any
	local wrapped = {}
	function wrapped.sendMessage(_self: any, opts: any): any
		return client.http(opts)
	end
	return wrapped
end

return Relay
```

- [ ] **Step 2: Implement `src/RelaySpec.luau`**

```lua
--!strict
-- RelaySpec: in-Studio self-test for the PURE surface of the relay — context mode (in edit), the
-- relay/local tool classification (and that it matches the registered tools), and wrapAnthropic
-- routing. The host/client (live RemoteFunction across the two play DataModels) are LIVE-verified in
-- Studio, not here. Run via temporarily adding `require(script.RelaySpec).run()` to init.server.luau,
-- build, reopen Studio, read Output.

local Relay = require(script.Parent.Relay)
local Tools = require(script.Parent.Tools)

local M = {}

-- The 16 custom (locally-dispatchable) tools, partitioned by where they run in client-view play.
local EXPECTED_LOCAL = {
	"update_tasks",
	"remember",
	"forget",
	"use_skill",
	"save_skill",
	"delete_skill",
}
local EXPECTED_RELAY = {
	"run_luau",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"set_property",
	"create_instance",
	"capture",
	"dispatch_subagents",
	"dispatch_writers",
}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("mode() returns 'edit' when run in edit", function()
		local m = Relay.mode()
		if m ~= "edit" then
			return false, "got " .. tostring(m)
		end
		return true
	end)

	add("shouldRelayTool: plugin-only tools run LOCAL (false)", function()
		for _, n in EXPECTED_LOCAL do
			if Relay.shouldRelayTool(n) ~= false then
				return false, n .. " should be local"
			end
		end
		return true
	end)

	add("shouldRelayTool: DataModel/HTTP/dispatch tools RELAY (true)", function()
		for _, n in EXPECTED_RELAY do
			if Relay.shouldRelayTool(n) ~= true then
				return false, n .. " should relay"
			end
		end
		return true
	end)

	add("every EXPECTED_LOCAL name is a real registered tool", function()
		for _, n in EXPECTED_LOCAL do
			if Tools.get(n) == nil then
				return false, "not registered: " .. n
			end
		end
		return true
	end)

	add("every EXPECTED_RELAY name is a real registered tool", function()
		for _, n in EXPECTED_RELAY do
			if Tools.get(n) == nil then
				return false, "not registered: " .. n
			end
		end
		return true
	end)

	add("classification covers the whole custom registry (no drift)", function()
		-- Every registered custom tool must appear in exactly one of the two expected lists, so a new
		-- tool added without updating the split fails here.
		local known: { [string]: boolean } = {}
		for _, n in EXPECTED_LOCAL do
			known[n] = true
		end
		for _, n in EXPECTED_RELAY do
			known[n] = true
		end
		for _, schema in (Tools :: any).schemas(nil) do
			local name = schema.name
			-- Server-side web tools (web_search/web_fetch) have no descriptor and are never dispatched
			-- locally; skip them (Tools.get is nil for them).
			if Tools.get(name) ~= nil and not known[name] then
				return false, "unclassified registered tool: " .. tostring(name)
			end
		end
		return true
	end)

	add("wrapAnthropic routes sendMessage through client.http", function()
		local captured: any = nil
		local stub = {
			http = function(opts: any): any
				captured = opts
				return { ok = true, data = { content = {} } }
			end,
		}
		local wrapped = Relay.wrapAnthropic(stub)
		local res = wrapped:sendMessage({ messages = { "x" }, maxTokens = 7 })
		if type(res) ~= "table" or res.ok ~= true then
			return false, "sendMessage did not return the stub Result"
		end
		if type(captured) ~= "table" or captured.maxTokens ~= 7 then
			return false, "opts not forwarded to client.http"
		end
		return true
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== RelaySpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	local passed = total - failed
	print(
		"=== Summary: "
			.. tostring(passed)
			.. "/"
			.. tostring(total)
			.. " passed, "
			.. tostring(failed)
			.. " failed ==="
	)
	return { passed = failed == 0, total = total, failed = failed }
end

return M
```

- [ ] **Step 3: Statically verify**

Run: `selene src` then `stylua --check src`
Expected: `selene` 0 errors / 0 warnings; `stylua --check` clean (run `stylua src` first if it reports a diff).

- [ ] **Step 4: Commit**

```bash
git add src/Relay.luau src/RelaySpec.luau
git commit -m "feat(relay): Relay module (mode/shouldRelayTool/startHost/newClient/wrapAnthropic) + RelaySpec"
```

---

## Task 2: thread `relay` through `AgentLoop`

**Files:**
- Modify: `src/AgentLoop.luau`

- [ ] **Step 1: Require Relay**

After `local Retry = require(script.Parent.Retry)` (near the top requires), add:

```lua
local Relay = require(script.Parent.Relay)
```

- [ ] **Step 2: Add `relay` to `runLoop`'s signature**

Change the `runLoop` signature (currently ending `..., skills, snapshot, cb)`) to add `relay` as the final param:

```lua
local function runLoop(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	memory: any,
	skills: any,
	snapshot: number,
	cb: Callbacks,
	relay: any
)
```

- [ ] **Step 3: Branch the tool-dispatch site through the relay**

Find the single dispatch line inside the tool loop:

```lua
				local content, isError = Tools.dispatch(block.name, block.input, toolContext)
```

Replace it with:

```lua
				-- In client-view play, relay DataModel/HTTP/dispatch tools to the server copy; run
				-- plugin-only tools (update_tasks/remember/forget/skills) locally. No relay -> all local
				-- (edit / Server-view play), exactly as today.
				local content, isError
				if relay ~= nil and Relay.shouldRelayTool(block.name) then
					content, isError = relay.tool(block.name, block.input)
				else
					content, isError = Tools.dispatch(block.name, block.input, toolContext)
				end
```

- [ ] **Step 4: Add `relay` to `AgentLoop.send` + pass it to `runLoop`**

Change the `AgentLoop.send` signature (currently ending `..., userText, cb)`) to add `relay` last:

```lua
function AgentLoop.send(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	memory: any,
	skills: any,
	userText: string,
	cb: Callbacks,
	relay: any
)
```

In the `pcall(runLoop, ...)` call inside `AgentLoop.send`, add `relay` as the final argument (it currently ends `..., skills, snapshot, cb)`):

```lua
		local ok, err = pcall(
			runLoop,
			anthropic,
			config,
			systemPrompt,
			conversation,
			taskList,
			memory,
			skills,
			snapshot,
			cb,
			relay
		)
```

- [ ] **Step 5: Statically verify + commit**

Run: `selene src` then `stylua --check src` (0 errors / clean).

```bash
git add src/AgentLoop.luau
git commit -m "feat(relay): thread optional relay through AgentLoop + branch tool dispatch"
```

---

## Task 3: pass `deps.relay` from the Widget

**Files:**
- Modify: `src/UI/Widget.luau`

- [ ] **Step 1: Make `deps.relay` the final arg to `send`**

In `sendBtn.Activated`, the `deps.agentLoop.send(...)` call currently ends with the callbacks table then `)`:

```lua
				}
			)
		end)
```

Change it so `deps.relay` is the new final argument after the callbacks table:

```lua
				},
				deps.relay
			)
		end)
```

(`deps.relay` is `nil` in edit / Server-view — `send` then runs all tools locally, exactly as today.)

- [ ] **Step 2: Statically verify + commit**

Run: `selene src` then `stylua --check src` (0 errors / clean).

```bash
git add src/UI/Widget.luau
git commit -m "feat(relay): Widget passes deps.relay to AgentLoop.send"
```

---

## Task 4: per-copy wiring in `init.server.luau`

**Files:**
- Modify: `src/init.server.luau`

- [ ] **Step 1: Require Relay**

After `local SkillStore = require(script.SkillStore)` (near the top requires), add:

```lua
local Relay = require(script.Relay)
```

- [ ] **Step 2: Wire the relay by copy context**

Immediately after the `deps` table is constructed (after the `}` that closes `local deps = { ... }`) and BEFORE `ensureMounted`, add:

```lua
-- Client-view relay (LIVE-VERIFIED 2026-06-18): Accurate Play Solo runs separate per-context plugin
-- copies. In the Play SERVER copy, host the relay RemoteFunction. In the Play CLIENT copy (the panel
-- the user sees in client view), build the relay client + swap deps.anthropic for a relay-aware one,
-- so the loop's HTTP + DataModel/dispatch tools run server-side. In edit / Server-view: no relay.
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
```

- [ ] **Step 3: Statically verify + commit**

Run: `selene src` then `stylua --check src` (0 errors / clean).

```bash
git add src/init.server.luau
git commit -m "feat(relay): per-copy wiring — host in serverplay, client+wrap in clientplay"
```

---

## Task 5: build, full lint, RelaySpec, adversarial review, live-verify

**Files:** none (verification + build artifact + docs)

- [ ] **Step 1: Full build + lint sweep**

Run: `.\build.ps1` (expect `rojo build` success → `StudioAgent.rbxm` installed). Then `selene src` (0 errors / 0 warnings — the `CreateDockWidgetPluginGui` warning is already resolved) and `stylua --check src` (clean).

- [ ] **Step 2: Run `RelaySpec` in Studio**

Temporarily add near the end of `src/init.server.luau`:

```lua
require(script.RelaySpec).run()
```

Build (`.\build.ps1`), reopen Studio on a NEW Baseplate, read Output for `=== Summary: N/N passed ===` (expect all pass). Then REMOVE that line and rebuild.

- [ ] **Step 3: Adversarial review (Workflow)**

Run an adversarial-review Workflow over the diff. Focus areas:
- The relay/local split: is any DataModel/HTTP tool wrongly classified LOCAL, or any plugin-only tool wrongly RELAYED? (`shouldRelayTool` + `LOCAL_TOOLS` vs the registry.)
- Host totality: can `OnServerInvoke` throw out of the pcall? Does it always return a table the client can unwrap?
- Client fallback: does every failure path (`InvokeServer` throws, RF absent, malformed reply) return a clean Result / is_error rather than crash the loop?
- Empty-object `{}` tool input survives the remote (sent as a table; server's `Anthropic.encodeBody` applies the `{}` fix).
- `pause_turn` / `server_tool_use` pass-through: the HTTP relay returns the full `Result.data` unchanged, so the loop's existing handling applies.
- Can the relay exist outside a Studio play session? (Plugin-only + ephemeral — confirm `mode()` gating + that nothing creates the RF in edit.)
- `wrapAnthropic` covers everything Retry + Compactor call (only `sendMessage`).
- Apply confirmed fixes; rebuild; re-lint.

- [ ] **Step 4: Live-verify in Studio (computer-use, NEW Baseplate, hecate tunnel up)**

Enter Play, STAY in the **client** view, and confirm WITHOUT switching to the Server view:
1. A no-tool prompt answers (HTTP relay round-trips).
2. `create_instance`/`set_property` build and the parts appear in the running game (tool relay → server DM).
3. `capture` returns a screenshot the agent reasons about (sidecar GET runs server-side; image block round-trips).
4. A `dispatch_writers` (or `dispatch_subagents`) fan-out runs (whole child fan-out executes server-side).
5. `update_tasks` ticks the checklist and `remember` persists (local tools still work in the client copy).
Then: press Stop and confirm an Explorer search for `StudioAgentRelay` is 0 matches (no leak). Finally confirm the **Server view** path still works (fallback parity) and **edit** mode is unchanged.

- [ ] **Step 5: Update HANDOFF + memory, final commit**

Update `HANDOFF.md` (mark roadmap item #5 done + the relay notes/gotchas) and the `studio-agent-status` memory. Remove the throwaway spike if desired (`spike/`, `spike.project.json`) or keep it as the documented verification harness.

```bash
git add -A
git commit -m "docs(relay): HANDOFF + status — client-view relay live-verified"
```

---

## Self-Review (run after writing; fix inline)

**Spec coverage** — each spec decision maps to a task:
- Loop stays client-side; relay the 2 choke points → Task 2 (dispatch branch) + Task 4 (wrap anthropic). ✓
- Bridge = replicated `RemoteFunction` `StudioAgentRelay` → Task 1 (`startHost`/`newClient`). ✓
- No injected Script (server plugin copy is the handler) → Task 1 (`startHost` sets `OnServerInvoke`). ✓
- Per-copy wiring at init from `RunService` → Task 4 + `Relay.mode()` (Task 1). ✓
- Relay vs local tool split (the 6 plugin-only LOCAL) → Task 1 (`LOCAL_TOOLS`/`shouldRelayTool`) + Task 2 (branch). ✓
- Relay payload = Luau tables over InvokeServer; server does encode → Task 1 (`http` sends `opts`; host calls `deps.anthropic:sendMessage`). ✓
- Graceful fallback (RF absent → context Result / is_error) → Task 1 (`newClient`/`http`/`tool` fallbacks) + nil-safe `relay` everywhere. ✓
- Safe-by-construction (plugin-only + ephemeral + Studio-gated host) → Task 1 (`mode()` gate) + Task 4 (only host in serverplay). ✓
- `web_search`/`web_fetch` need no handling (ride the HTTP response) → covered by the HTTP relay; RelaySpec skips them (no descriptor). ✓
- Testing (RelaySpec, adversarial review, live-verify) → Task 1 + Task 5. ✓

**Type/name consistency** — `Relay.mode()` ("edit"/"serverplay"/"clientplay"/"other"); `Relay.shouldRelayTool(name)`; `Relay.startHost(deps)`; `Relay.newClient()` → `client.http(opts)` / `client.tool(name, input)`; `Relay.wrapAnthropic(client)` → `:sendMessage(opts)`; request envelopes `{kind="http", opts}` / `{kind="tool", name, input}`; reply envelopes `{kind="http", result}` / `{kind="tool", content, isError}`; `LOCAL_TOOLS` (6 names) matches `EXPECTED_LOCAL` in RelaySpec; `deps.relay`; the `relay` param order (last) in `send`/`runLoop` + the matching `pcall(runLoop, ...)` arg. All consistent across tasks. ✓

**Placeholder scan** — every code step shows complete code; no TBD / "handle edge cases" / "similar to". ✓

**Ordering note** — Tasks build clean in any order because `relay` is optional + nil-safe: Task 1 adds an unused module; Task 2's branch is dead until a non-nil `relay` arrives; Task 3 passes `deps.relay` (nil until Task 4 sets it); Task 4 wires it. Full behavior is live only after all four + a build (Task 5). ✓
