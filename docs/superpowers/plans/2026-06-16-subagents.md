# Subagents (`dispatch_subagents`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the in-Studio parent agent fan out read-only child agents in parallel (`dispatch_subagents`) for exploration/verification/judging, with the parent staying the sole builder.

**Architecture:** A new `dispatch_subagents` tool spawns N ephemeral child loops via `task.spawn`; each child (`Subagent.luau`) is a minimal read-only send→dispatch loop on Sonnet with an allowlisted toolset, isolated from the stabilized parent `runLoop`. The shared transient-retry path is factored into `Retry.luau`. Children can't write (allowlist enforced at `Tools.dispatch`) and can't nest (`dispatch_subagents` excluded from their allowlist → depth-1).

**Tech Stack:** Luau (`--!strict`), rojo, selene + stylua. Pure pieces tested by an in-Studio `SubagentsSpec` (like `CompactorSpec`).

---

## Testing model (read first)

Same as the compaction plan: **agent-runnable gates after every task** —
```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
(`selene` exits 1 only on the known `CreateDockWidgetPluginGui` deprecation — "0 errors" is the pass.) The **pure** behavior is covered by `src/SubagentsSpec.luau`, run in Studio by temporarily adding `require(script.SubagentsSpec).run()` to `init.server.luau`. The live child loop + parallel join get static gates + an adversarial review + a Studio live test. Commit after each task.

## File structure

- **Create `src/Retry.luau`** — `isTransient` + `sendWithRetry`, moved verbatim from `AgentLoop`.
- **Modify `src/AgentLoop.luau`** — require `Retry`, delete the two local copies, call `Retry.sendWithRetry`.
- **Modify `src/Config.luau`** — `subagentModel` / `subagentMaxParallel` / `subagentMaxIterations`.
- **Modify `src/Tools/init.luau`** — `schemasFor(names)`, allowlist enforcement in `dispatch`, register `dispatch_subagents`.
- **Create `src/Subagent.luau`** — the minimal read-only child runner.
- **Modify `src/SystemPrompt.luau`** — parent "fan out" section + `buildSubagent(role)`.
- **Create `src/Tools/Subagents.luau`** — the `dispatch_subagents` tool.
- **Create `src/SubagentsSpec.luau`** — in-Studio pure-piece self-test.

---

### Task 1: `Retry` — extract the shared retry path

**Files:**
- Create: `src/Retry.luau`
- Modify: `src/AgentLoop.luau:17-19` (require), `:28-86` (delete locals), `:164` (call site)

- [ ] **Step 1: Create `src/Retry.luau`** (the two functions moved verbatim)

```lua
--!strict
-- Retry: the transient-error classification + capped-exponential-backoff send, shared by the parent
-- AgentLoop and the read-only Subagent runner. Policy (single source of truth): Overloaded / 429 /
-- 5xx / transport / the cold-proxy "unknown provider" race are RETRYABLE; the subscription
-- usage-window ("out of extra usage") is NOT (retrying re-reserves max_tokens and worsens it).

local Retry = {}

-- Worth retrying? Transient server/transport conditions, NOT the usage-window or a real client error.
function Retry.isTransient(res: any): boolean
	if res.kind == "transport" then
		return true
	end
	if res.kind == "http" then
		local status = res.status
		if status == 408 or status == 409 or status == 429 then
			return true
		end
		if status == 500 or status == 502 or status == 503 or status == 504 or status == 529 then
			return true
		end
		local msg = string.lower(tostring(res.message))
		if string.find(msg, "out of extra usage", 1, true) then
			return false
		end
		if string.find(msg, "overloaded", 1, true) then
			return true
		end
		if string.find(msg, "unknown provider for model", 1, true) then
			return true
		end
	end
	return false
end

-- sendMessage with capped exponential backoff on transient failures.
function Retry.sendWithRetry(
	anthropic: any,
	config: any,
	opts: any,
	emit: (string, any) -> (),
	cancelled: () -> boolean
): any
	local maxAttempts = config:getRetryMaxAttempts()
	local base = config:getRetryBaseDelay()
	local maxDelay = config:getRetryMaxDelay()
	local attempt = 0
	while true do
		attempt += 1
		local res = anthropic:sendMessage(opts)
		if res.ok then
			return res
		end
		if attempt >= maxAttempts or cancelled() or not Retry.isTransient(res) then
			return res
		end
		local delay = math.min(maxDelay, base * 2 ^ (attempt - 1))
		emit(
			"status",
			"transient error ("
				.. tostring(res.kind)
				.. ") - retrying in "
				.. string.format("%.1fs", delay)
		)
		task.wait(delay)
	end
end

return Retry
```

- [ ] **Step 2: Require `Retry` in `AgentLoop`**

In `src/AgentLoop.luau`, change the require block:

```lua
local Tools = require(script.Parent.Tools)
local Compactor = require(script.Parent.Compactor)
local MessageUtil = require(script.Parent.MessageUtil)
local Retry = require(script.Parent.Retry)
```

- [ ] **Step 3: Delete the two local functions**

Delete the entire `local function isTransient(res: any): boolean ... end` block AND the
`local function sendWithRetry(...) ... end` block (currently `src/AgentLoop.luau:28-86`, the two
functions plus their leading comments).

- [ ] **Step 4: Update the call site**

In `runLoop`, change `res = sendWithRetry(` to `res = Retry.sendWithRetry(` (currently
`src/AgentLoop.luau:164`).

- [ ] **Step 5: Static gates**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
Expected: stylua clean, selene "0 errors", rojo build exit 0. (Mechanical extraction — no behavior change; the existing loop still works.)

- [ ] **Step 6: Commit**

```bash
git add src/Retry.luau src/AgentLoop.luau
git commit -m "refactor: extract shared transient-retry path into Retry.luau"
```

---

### Task 2: `Config` subagent knobs

**Files:** Modify `src/Config.luau`

- [ ] **Step 1: Defaults**

In `DEFAULTS`, after the compaction knobs, add:

```lua
	-- Subagents (dispatch_subagents).
	subagentModel = "claude-sonnet-4-6", -- children run on the cheaper/faster model
	subagentMaxParallel = 4, -- max children per dispatch (excess truncated + reported)
	subagentMaxIterations = 15, -- per-child step cap
```

- [ ] **Step 2: Validation** (before the final `self._plugin:SetSetting`)

```lua
	elseif key == "subagentModel" then
		if type(value) ~= "string" or not isAllowedModel(value) then
			return false, "subagentModel must be one of the allowed MODELS"
		end
	elseif key == "subagentMaxParallel" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "subagentMaxParallel must be >= 1"
		end
		value = math.floor(value)
	elseif key == "subagentMaxIterations" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "subagentMaxIterations must be >= 1"
		end
		value = math.floor(value)
```

- [ ] **Step 3: Getters** (near the other getters)

```lua
function Config.getSubagentModel(self: Config): string
	return self:get("subagentModel") :: string
end

function Config.getSubagentMaxParallel(self: Config): number
	return self:get("subagentMaxParallel") :: number
end

function Config.getSubagentMaxIterations(self: Config): number
	return self:get("subagentMaxIterations") :: number
end
```

- [ ] **Step 4: Gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/Config.luau
git commit -m "feat: config knobs for subagents (model, max parallel, max iterations)"
```

---

### Task 3: `Tools` — `schemasFor` + allowlist enforcement

**Files:** Modify `src/Tools/init.luau`

- [ ] **Step 1: Add `schemasFor`** (after the `Tools.schemas` function)

```lua
-- Like schemas(), but filtered to a named subset (used to give a subagent a read-only toolset).
function Tools.schemasFor(names: { string }): { any }
	local want: { [string]: boolean } = {}
	for _, n in names do
		want[n] = true
	end
	local out: { any } = {}
	for _, descriptor in registry do
		if want[descriptor.name] then
			table.insert(out, {
				name = descriptor.name,
				description = descriptor.description,
				input_schema = descriptor.inputSchema,
			})
		end
	end
	return out
end
```

- [ ] **Step 2: Enforce the allowlist in `dispatch`** (add the guard before the `pcall`)

```lua
function Tools.dispatch(name: string, input: any, context: any): (Content, boolean)
	local descriptor = byName[name]
	if descriptor == nil then
		return "unknown tool: " .. tostring(name), true
	end
	-- Subagent allowlist: when a context carries `allowedTools`, a tool NOT in the set is rejected
	-- WITHOUT running. An allowlist (not a destructive-flag check) is required because
	-- dispatch_subagents is itself non-destructive — only an allowlist blocks both writers AND nesting.
	if
		type(context) == "table"
		and type(context.allowedTools) == "table"
		and not context.allowedTools[name]
	then
		return "'" .. tostring(name) .. "' is not permitted for this subagent", true
	end
	local ok, content, isError = pcall(descriptor.run, input, context)
	if not ok then
		return "tool handler error: " .. tostring(content), true
	end
	if type(content) ~= "string" and type(content) ~= "table" then
		return tostring(content), isError == true
	end
	return content, isError == true
end
```

- [ ] **Step 3: Gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/Tools/init.luau
git commit -m "feat: Tools.schemasFor + allowlist enforcement at dispatch (subagent guardrail)"
```

---

### Task 4: `Subagent` — the read-only child runner

**Files:** Create `src/Subagent.luau`

- [ ] **Step 1: Create `src/Subagent.luau`**

```lua
--!strict
-- Subagent: a minimal, ephemeral, READ-ONLY child agent loop used by the dispatch_subagents tool.
-- Unlike AgentLoop.runLoop it has NO rollback / compaction / persistence / single-flight — children
-- are throwaway and never persisted. It shares the transient-retry path (Retry) with the parent loop.
-- run() returns the child's final assistant text (its entire contribution back to the parent).

local Tools = require(script.Parent.Tools)
local Retry = require(script.Parent.Retry)

local Subagent = {}

export type Opts = {
	anthropic: any,
	config: any,
	systemPrompt: string,
	taskPrompt: string,
	toolSchemas: { any },
	allowedTools: { [string]: boolean },
	model: string,
	maxIterations: number,
	shouldCancel: (() -> boolean)?,
}

export type Result = { text: string, ok: boolean, capped: boolean }

local function noop(_event: string, _data: any) end

-- Concatenate the text blocks of an assistant response's content array.
local function collectText(content: any): string
	if type(content) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	for _, block in ipairs(content) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			table.insert(parts, block.text)
		end
	end
	return table.concat(parts, "")
end

function Subagent.run(opts: Opts): Result
	local cancelled = function(): boolean
		return opts.shouldCancel ~= nil and opts.shouldCancel()
	end
	local context = {
		config = opts.config,
		anthropic = opts.anthropic,
		allowedTools = opts.allowedTools,
	}
	local messages: { any } = { { role = "user", content = opts.taskPrompt } }
	local lastText = ""

	for _ = 1, opts.maxIterations do
		if cancelled() then
			return { text = lastText, ok = true, capped = false }
		end
		local res = Retry.sendWithRetry(opts.anthropic, opts.config, {
			messages = messages,
			tools = opts.toolSchemas,
			system = opts.systemPrompt,
			model = opts.model,
		}, noop, cancelled)
		if not res.ok then
			return {
				text = "subagent request error: " .. tostring(res.message),
				ok = false,
				capped = false,
			}
		end
		local data = res.data
		if type(data) ~= "table" or type(data.content) ~= "table" then
			return { text = "subagent: malformed response", ok = false, capped = false }
		end

		local toolUses: { any } = {}
		for _, block in ipairs(data.content) do
			if type(block) == "table" and block.type == "tool_use" then
				table.insert(toolUses, block)
			end
		end

		if #toolUses == 0 then
			-- Terminal turn: the child's final text is its return value.
			return { text = collectText(data.content), ok = true, capped = false }
		end

		local toolResults: { any } = {}
		for _, block in ipairs(toolUses) do
			local content, isError = Tools.dispatch(block.name, block.input, context)
			if type(content) == "string" and content == "" then
				content = "(no output)"
			end
			table.insert(toolResults, {
				type = "tool_result",
				tool_use_id = block.id,
				content = content,
				is_error = isError,
			})
		end
		table.insert(messages, { role = "assistant", content = data.content })
		table.insert(messages, { role = "user", content = toolResults })
		lastText = collectText(data.content)
	end

	return {
		text = if lastText ~= "" then lastText else "(subagent hit its step limit before reporting)",
		ok = true,
		capped = true,
	}
end

return Subagent
```

- [ ] **Step 2: Gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/Subagent.luau
git commit -m "feat: Subagent — minimal read-only ephemeral child agent loop"
```

---

### Task 5: `SystemPrompt` — parent fan-out section + `buildSubagent`

**Files:** Modify `src/SystemPrompt.luau`

- [ ] **Step 1: Add the parent "fan out" section** to `BASE`

Insert this section in the `BASE` string, right before the `# Working rules` line:

```
# Fanning out subagents
You can call dispatch_subagents to run READ-ONLY children IN PARALLEL — each a fresh agent that explores, verifies, or judges and returns a terse text report. Use it for read-heavy or parallelizable work: several finders over different parts of the place at once; an adversarial verifier to independently double-check something you JUST built (it can capture and inspect, then report pass/fail with specifics); or a judge panel for a design decision. Children CANNOT modify anything and cannot spawn their own subagents — YOU do all building, then optionally fan out to verify or explore. Give each child a short `role` and a SELF-CONTAINED `prompt` (it sees none of this conversation); you get back each child's final text to synthesize. Don't fan out for a trivial single read you can do yourself.
```

- [ ] **Step 2: Add `buildSubagent`** (after the `SystemPrompt.build` function, before `return SystemPrompt`)

```lua
local SUBAGENT_BASE = [[
You are a READ-ONLY subagent operating inside Roblox Studio, dispatched by a parent build agent to do ONE focused task. You CANNOT modify anything — you have only read tools. You cannot spawn other subagents.

# Your tools
- get_tree(path, depth): explore the instance hierarchy under a path.
- search(root, name, className): find instances by name substring and/or class.
- get_properties(path): read an instance's typed properties.
- get_output(limit, errorsOnly): read recent Studio Output, including runtime script errors.
- capture(window?): screenshot the Studio window and SEE it (to inspect GUIs/scenes visually).

# Addressing instances
Instances are addressed by a CASE-SENSITIVE, dot-separated path from a top-level service, e.g. game.Workspace.Model.Part. Common roots: game.Workspace, game.ReplicatedStorage, game.ServerScriptService, game.StarterGui, game.StarterPlayer, game.Lighting.

# Value encoding (results come back tagged)
get_properties results are tagged tables: Instance -> {"__t":"Instance","class":..,"name":..,"path":[..]}; Vector3 -> {"__t":"Vector3","x":..,"y":..,"z":..}; CFrame -> {"__t":"CFrame","c":[..12 floats..]}; Color3 -> {"__t":"Color3","r":..,"g":..,"b":..} (0..1); UDim2 -> {"__t":"UDim2","xs":..,"xo":..,"ys":..,"yo":..}; EnumItem -> {"__t":"EnumItem","enum":..,"item":..}.

# OUTPUT CONTRACT (critical)
Your FINAL message is your ENTIRE return value to the parent. The parent CANNOT see your tool calls, your intermediate reasoning, or any screenshot you took — only your final text. So your final message must be TERSE, STRUCTURED, and COMPLETE: state your findings or verdict directly with concrete specifics (instance paths, property values, what you saw). Do the task using your read tools, then report.
]]

-- A focused system prompt for a read-only child subagent with the given role.
function SystemPrompt.buildSubagent(role: string): string
	return SUBAGENT_BASE .. "\n# Your role\n" .. tostring(role) .. "\n"
end
```

- [ ] **Step 3: Gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/SystemPrompt.luau
git commit -m "feat: SystemPrompt fan-out guidance + buildSubagent child prompt"
```

---

### Task 6: `dispatch_subagents` tool + registration

**Files:**
- Create: `src/Tools/Subagents.luau`
- Modify: `src/Tools/init.luau` (require + register)

- [ ] **Step 1: Create `src/Tools/Subagents.luau`**

```lua
--!strict
-- Subagents: the dispatch_subagents tool. The parent agent fans out READ-ONLY child agents that run
-- IN PARALLEL (on the subagent model), each exploring/verifying/judging, and returns each child's
-- terse final text as one JSON tool_result. Children cannot mutate (allowlist enforced at
-- Tools.dispatch) and cannot nest (dispatch_subagents is not in their allowlist -> depth-1).
--
-- Tools/init requires this module at load to register the tool; the Subagent runner + the Tools
-- registry are required LAZILY inside run() to avoid a module-load require cycle.

local HttpService = game:GetService("HttpService")
local SystemPrompt = require(script.Parent.Parent.SystemPrompt)

local Subagents = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local READ_ONLY = { "get_tree", "search", "get_properties", "get_output", "capture" }

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"subagent result not JSON-encodable"}'
end

local function runDispatch(input: any, context: any): (string, boolean)
	local config = if type(context) == "table" then context.config else nil
	local anthropic = if type(context) == "table" then context.anthropic else nil
	if config == nil or anthropic == nil then
		return encodeResult({ ok = false, error = "dispatch_subagents: missing config/anthropic" }),
			true
	end

	local args = if type(input) == "table" then input else {}
	local subs = args.subagents
	if type(subs) ~= "table" or #subs == 0 then
		return encodeResult({
			ok = false,
			error = "dispatch_subagents requires { subagents = [ { role, prompt }, ... ] } (at least 1)",
		}),
			true
	end

	-- Lazy requires break the Tools <- Subagents <- Subagent <- Tools load-time cycle.
	local Tools = require(script.Parent)
	local Subagent = require(script.Parent.Parent.Subagent)

	local cap = config:getSubagentMaxParallel()
	local n = math.min(#subs, cap)
	local dropped = #subs - n

	local toolSchemas = (Tools :: any).schemasFor(READ_ONLY)
	local allowed: { [string]: boolean } = {}
	for _, name in READ_ONLY do
		allowed[name] = true
	end

	local model = config:getSubagentModel()
	local maxIter = config:getSubagentMaxIterations()
	local shouldCancel = if type(context) == "table" then context.shouldCancel else nil

	local results: { any } = {}
	local done = 0
	for i = 1, n do
		local sub = subs[i]
		local role = if type(sub) == "table" and type(sub.role) == "string"
			then sub.role
			else "subagent " .. i
		local prompt = if type(sub) == "table" and type(sub.prompt) == "string" then sub.prompt else ""
		task.spawn(function()
			local ok, res = pcall((Subagent :: any).run, {
				anthropic = anthropic,
				config = config,
				systemPrompt = SystemPrompt.buildSubagent(role),
				taskPrompt = prompt,
				toolSchemas = toolSchemas,
				allowedTools = allowed,
				model = model,
				maxIterations = maxIter,
				shouldCancel = shouldCancel,
			})
			if ok and type(res) == "table" then
				results[i] = { role = role, ok = res.ok, capped = res.capped, text = res.text }
			else
				results[i] =
					{ role = role, ok = false, capped = false, text = "subagent error: " .. tostring(res) }
			end
			done += 1
		end)
	end

	-- Join. The parent loop is yielding here, so it is NOT writing -> the DataModel is quiescent for
	-- the children's reads. Cooperative scheduling means results[i] writes never interleave.
	while done < n do
		task.wait()
	end

	local out: { any } = {}
	for i = 1, n do
		out[i] = results[i]
	end
	local payload: { [string]: any } = { ok = true, count = n, results = out }
	if dropped > 0 then
		payload.dropped = dropped
	end
	return encodeResult(payload), false
end

Subagents.descriptors = {
	{
		name = "dispatch_subagents",
		description = "Fan out READ-ONLY subagents that run IN PARALLEL to explore, analyze, verify, "
			.. "or judge, then return each one's final text report. Use for read-heavy or "
			.. "parallelizable work: several finders over different areas at once; an adversarial "
			.. "verifier to independently double-check something YOU just built; or a judge panel for "
			.. "a design decision. Children CANNOT modify anything (you do all building) and cannot "
			.. "spawn their own subagents. Each child sees NONE of your context — give it a "
			.. "self-contained `prompt` and a short `role`, and expect a terse text report back.",
		inputSchema = {
			type = "object",
			properties = {
				subagents = {
					type = "array",
					description = "One or more read-only children to run in parallel.",
					items = {
						type = "object",
						properties = {
							role = {
								type = "string",
								description = "Short label, e.g. 'gui-auditor'.",
							},
							prompt = {
								type = "string",
								description = "Self-contained task for this child (it sees none of your chat).",
							},
						},
						required = { "role", "prompt" },
					},
				},
			},
			required = { "subagents" },
		},
		destructive = false,
		run = runDispatch,
	},
} :: { Descriptor }

return Subagents
```

- [ ] **Step 2: Register it** in `src/Tools/init.luau`

Add the require near the other tool requires (after `local CaptureTool = require(script.Capture)`):

```lua
local SubagentsTool = require(script.Subagents)
```

Add the concatenation block (after the `CaptureTool.descriptors` loop):

```lua
for _, descriptor in SubagentsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

- [ ] **Step 3: Gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/Tools/Subagents.luau src/Tools/init.luau
git commit -m "feat: dispatch_subagents tool (parallel read-only children) + register"
```

---

### Task 7: `SubagentsSpec` — pure-piece self-test

**Files:** Create `src/SubagentsSpec.luau`

- [ ] **Step 1: Create `src/SubagentsSpec.luau`**

```lua
--!strict
-- SubagentsSpec: in-Studio self-test for the PURE subagent pieces (no network). Run via temporarily
-- adding `require(script.SubagentsSpec).run()` to init.server.luau, build, reopen Studio, read Output.

local Tools = require(script.Parent.Tools)

local M = {}

local READ_ONLY = { "get_tree", "search", "get_properties", "get_output", "capture" }

local function allowedSet(): { [string]: boolean }
	local a: { [string]: boolean } = {}
	for _, n in READ_ONLY do
		a[n] = true
	end
	return a
end

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("schemasFor returns exactly the read-only set", function()
		local s = (Tools :: any).schemasFor(READ_ONLY)
		if #s ~= #READ_ONLY then
			return false, "got " .. tostring(#s) .. " schemas"
		end
		local names: { [string]: boolean } = {}
		for _, t in s do
			names[t.name] = true
		end
		for _, n in READ_ONLY do
			if not names[n] then
				return false, "missing " .. n
			end
		end
		return true
	end)

	add("schemasFor excludes writers and dispatch_subagents", function()
		local s = (Tools :: any).schemasFor(READ_ONLY)
		for _, t in s do
			if
				t.name == "create_instance"
				or t.name == "run_luau"
				or t.name == "set_property"
				or t.name == "dispatch_subagents"
			then
				return false, "leaked " .. t.name
			end
		end
		return true
	end)

	add("dispatch allowlist rejects a writer (create_instance)", function()
		local _, isError =
			Tools.dispatch("create_instance", { className = "Part" }, { allowedTools = allowedSet() })
		return isError == true
	end)

	add("dispatch allowlist rejects dispatch_subagents (depth-1)", function()
		local _, isError =
			Tools.dispatch("dispatch_subagents", { subagents = {} }, { allowedTools = allowedSet() })
		return isError == true
	end)

	add("dispatch allowlist allows a read tool (get_tree)", function()
		local text, isError =
			Tools.dispatch("get_tree", { path = "game", depth = 0 }, { allowedTools = allowedSet() })
		return isError == false and type(text) == "string"
	end)

	add("dispatch without allowlist still permits writers (parent path unchanged)", function()
		-- No allowedTools in context -> the guard does not apply. get_tree must still work normally.
		local _, isError = Tools.dispatch("get_tree", { path = "game", depth = 0 }, { config = nil })
		return isError == false
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== SubagentsSpec: running " .. tostring(total) .. " cases ===")
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

- [ ] **Step 2: Gates**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```

- [ ] **Step 3: Run the spec in Studio (user/driver)**

Temporarily append `require(script.SubagentsSpec).run()` to `src/init.server.luau` before the final
`print`, `./build.ps1`, reopen Studio, confirm `=== Summary: 6/6 passed, 0 failed ===`, then remove
the line and rebuild.

- [ ] **Step 4: Commit**

```bash
git add src/SubagentsSpec.luau
git commit -m "test: SubagentsSpec — schemasFor + allowlist enforcement self-test"
```

---

### Task 8: Verification

- [ ] **Step 1: Full static gates + install**

```powershell
stylua --check src ; selene src ; ./build.ps1
```

- [ ] **Step 2: Run `SubagentsSpec` in Studio** — confirm `6/6 passed` (see Task 7 Step 3).

- [ ] **Step 3: Adversarial review workflow** over the diff: the lazy-require cycle safety, the
  parallel `task.spawn` + counter join (no deadlock; returns after all children; `task.wait()` yields
  so children progress), the allowlist actually blocking writers AND `dispatch_subagents`, the child
  runner's terminal/cap/cancel/error paths, that a child never mutates the parent Conversation, and
  the subscription-usage-window handling. Fix confirmed findings.

- [ ] **Step 4: Live test (Studio, via computer-use)** — ask the agent: "Fan out 3 subagents to
  analyze three different parts of the Workspace in parallel and report what each found." Confirm:
  parallel children run, each returns a terse report, the parent synthesizes, and NOTHING in the
  DataModel was changed by a child. Also try "have a subagent verify the part you just built" after a
  build.

- [ ] **Step 5: Update HANDOFF + memory** — mark subagents done; note web-access is the likely next
  capability.

---

## Self-review notes

- **Spec coverage:** Retry extraction (Task 1), Subagent runner (Task 4), dispatch tool (Task 6),
  schemasFor + allowlist enforcement (Task 3), Config knobs (Task 2), SystemPrompt parent section +
  buildSubagent (Task 5), SubagentsSpec (Task 7), live test (Task 8) — all mapped. Read-only +
  depth-1 enforced by the allowlist (Task 3 + the READ_ONLY set excluding dispatch_subagents).
- **Type consistency:** `Subagent.Opts` fields (`systemPrompt`/`taskPrompt`/`toolSchemas`/
  `allowedTools`/`model`/`maxIterations`/`shouldCancel`) match the call in Task 6; `Tools.schemasFor`
  and the `allowedTools` dispatch context key match between Tasks 3, 4, 6, 7; `getSubagentModel`/
  `getSubagentMaxParallel`/`getSubagentMaxIterations` (Task 2) are used in Task 6.
- **Require-cycle:** `Subagents.luau` requires `SystemPrompt` at load (no cycle) and `Tools`/`Subagent`
  lazily inside `run()` (Task 6) — breaks the load-time cycle.
- **Parent path unchanged:** the `dispatch` allowlist guard only fires when `context.allowedTools` is
  present; the parent never sets it, so parent tool calls are byte-for-byte unchanged (covered by a
  SubagentsSpec case).
