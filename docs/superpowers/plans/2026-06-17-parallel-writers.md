# Parallel Writer Subagents (`dispatch_writers`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `dispatch_writers` tool that fans out parallel WRITER subagents, each confined to a region of the DataModel, so large builds finish ~N× faster (overlapping LLM round-trips) — all inside one Studio instance.

**Architecture:** Writer children reuse the existing `Subagent.run` loop with a structured-only toolset (no `run_luau`), a `RegionGuard` on `create_instance`/`set_property` (via `context.writeRegion`), and disjoint regions. Cooperative scheduling + synchronous structured writes make per-call ChangeHistory recordings atomic, so parallel writers are safe.

**Tech Stack:** Luau (`--!strict`), Rojo, selene, stylua. No new deps. Static verification: `selene src` (0 errors) + `stylua --check src` + `rojo build` via `.\build.ps1`. Logic test: in-Studio `WritersSpec`.

**Verification reality (from HANDOFF):** Luau using Roblox APIs can't run here — each task is statically verified with `selene src` (0 errors) + `stylua --check src`; the `WritersSpec` is run in Studio by the user; live behavior is verified by driving Studio (in a NEW Baseplate per the test-session preference).

---

## File Structure

**Create:**
- `src/Tools/RegionGuard.luau` — confine a write to a region subtree (`within`/`check`); no-op when no region set.
- `src/Tools/Writers.luau` — the `dispatch_writers` tool (mirrors `Tools/Subagents.luau`).
- `src/WritersSpec.luau` — in-Studio self-test (allowlist + schema + RegionGuard).

**Modify:**
- `src/Tools/Create.luau` — `runCreate(input, context)`: region-guard the resolved `parent`.
- `src/Tools/Properties.luau` — `runSetProperty(input, context)`: region-guard the target + the re-parent escape.
- `src/Config.luau` — `writerModel`/`writerMaxParallel`/`writerMaxIterations` + getters.
- `src/Subagent.luau` — thread `opts.writeRegion` into the child's tool context.
- `src/Tools/init.luau` — require + register `Writers.descriptors`.
- `src/SystemPrompt.luau` — `buildWriter(region, task)` + parent "# Parallel building" section + tool line.

---

## Task 1: `RegionGuard` + guard the structured write tools

**Files:**
- Create: `src/Tools/RegionGuard.luau`
- Modify: `src/Tools/Create.luau`, `src/Tools/Properties.luau`

- [ ] **Step 1: Implement `src/Tools/RegionGuard.luau`**

```lua
--!strict
-- RegionGuard: confines a writer subagent's edits to its assigned region subtree. create_instance /
-- set_property call check() when context.writeRegion is set (parallel writer children). When it is
-- absent (the serial parent's normal writes), check() is a no-op, so existing behavior is unchanged.

local RegionGuard = {}

-- True if `target` is the region root itself or a descendant of it.
function RegionGuard.within(target: Instance, region: Instance): boolean
	return target == region or target:IsDescendantOf(region)
end

-- Gate a write at `target` against context.writeRegion. Returns (true) when no region is set, or the
-- target is within the region; (false, errMsg) when the target is outside the region.
function RegionGuard.check(target: Instance, context: any): (boolean, string?)
	local region = if type(context) == "table" then context.writeRegion else nil
	if region == nil then
		return true
	end
	if typeof(region) ~= "Instance" then
		return true
	end
	if RegionGuard.within(target, region) then
		return true
	end
	return false, "write outside your assigned region (" .. region:GetFullName() .. ") is not permitted"
end

return RegionGuard
```

- [ ] **Step 2: Guard `create_instance` (`src/Tools/Create.luau`)**

Add the require near the top (after `local Path = require(script.Parent.Path)`):

```lua
local RegionGuard = require(script.Parent.RegionGuard)
```

Change the function signature `local function runCreate(input: any): (string, boolean)` to:

```lua
local function runCreate(input: any, context: any): (string, boolean)
```

Immediately after the parent-resolution block (after the `if parent == nil then ... end`), add the guard:

```lua
	-- Region guard (parallel writer): the parent must be within the writer's assigned region. No-op
	-- for the serial parent (no context.writeRegion).
	local okRegion, regionErr = RegionGuard.check(parent, context)
	if not okRegion then
		return encodeResult({ ok = false, error = regionErr }), true
	end
```

Update the `Descriptor` type's `run` field in this file to `run: (input: any, context: any) -> (string, boolean)`.

- [ ] **Step 3: Guard `set_property` (`src/Tools/Properties.luau`)**

Add the require near the other requires at the top of the file:

```lua
local RegionGuard = require(script.Parent.RegionGuard)
```

Change `local function runSetProperty(input: any): (string, boolean)` to:

```lua
local function runSetProperty(input: any, context: any): (string, boolean)
```

After `local target = inst :: Instance` (the resolved target), add the target guard:

```lua
	-- Region guard (parallel writer): the target must be within the writer's assigned region.
	local okRegion, regionErr = RegionGuard.check(target, context)
	if not okRegion then
		return encodeResult({ ok = false, error = regionErr }), true
	end
```

After the `decoded` value is computed and the `isUnresolvableReference` check passes (i.e. just before the `local rid: string? = nil` recording block), add the re-parent escape guard:

```lua
	-- Re-parent escape guard: a writer must not move an in-region instance OUT of its region.
	if name == "Parent" and typeof(decoded) == "Instance" then
		local okReparent = RegionGuard.check(decoded :: Instance, context)
		if not okReparent then
			return encodeResult({
				ok = false,
				error = "re-parent outside your assigned region is not permitted",
			}),
				true
		end
	end
```

Update the `Descriptor` type's `run` field in this file (the `set_property` descriptor uses `run = runSetProperty`; the shared `Descriptor` type's `run` must allow the 2-arg form): `run: (input: any, context: any) -> (string, boolean)`. (`get_properties`'s `runGetProperties(input)` is unaffected — Lua ignores the extra arg.)

- [ ] **Step 4: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: `selene` 0 errors (only the known `CreateDockWidgetPluginGui` warning); `stylua --check` clean (run `stylua src` first if needed).

- [ ] **Step 5: Commit**

```bash
git add src/Tools/RegionGuard.luau src/Tools/Create.luau src/Tools/Properties.luau
git commit -m "feat(writers): RegionGuard + region-guard create_instance/set_property (context-gated)"
```

---

## Task 2: Config writer knobs

**Files:**
- Modify: `src/Config.luau`

- [ ] **Step 1: Add defaults**

In `DEFAULTS`, after the subagent block, add:

```lua
	-- Parallel writers (dispatch_writers).
	writerModel = "claude-sonnet-4-6", -- focused partitioned tasks; bump to opus for accuracy
	writerMaxParallel = 3, -- max writer children per dispatch (excess truncated + reported)
	writerMaxIterations = 20, -- per-child step cap
```

- [ ] **Step 2: Add validation**

In `Config.set`, after the `subagentMaxIterations` branch, add:

```lua
	elseif key == "writerModel" then
		if type(value) ~= "string" or not isAllowedModel(value) then
			return false, "writerModel must be one of the allowed MODELS"
		end
	elseif key == "writerMaxParallel" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "writerMaxParallel must be >= 1"
		end
		value = math.floor(value)
	elseif key == "writerMaxIterations" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "writerMaxIterations must be >= 1"
		end
		value = math.floor(value)
```

- [ ] **Step 3: Add getters**

After `Config.getSubagentMaxIterations`, add:

```lua
function Config.getWriterModel(self: Config): string
	return self:get("writerModel") :: string
end

function Config.getWriterMaxParallel(self: Config): number
	return self:get("writerMaxParallel") :: number
end

function Config.getWriterMaxIterations(self: Config): number
	return self:get("writerMaxIterations") :: number
end
```

- [ ] **Step 4: Statically verify + commit**

Run: `selene src` and `stylua --check src` (0 errors / clean).

```bash
git add src/Config.luau
git commit -m "feat(writers): Config knobs (writerModel/writerMaxParallel/writerMaxIterations)"
```

---

## Task 3: thread `writeRegion` into `Subagent`

**Files:**
- Modify: `src/Subagent.luau`

- [ ] **Step 1: Add `writeRegion` to `Opts`**

In the `Opts` export type, add a field (after `shouldCancel`):

```lua
	writeRegion: Instance?,
```

- [ ] **Step 2: Thread it into the child's tool context**

Change the `context` table in `Subagent.run` (currently `{ config = opts.config, anthropic = opts.anthropic, allowedTools = opts.allowedTools }`) to:

```lua
	local context = {
		config = opts.config,
		anthropic = opts.anthropic,
		allowedTools = opts.allowedTools,
		writeRegion = opts.writeRegion, -- nil for read-only subagents; a region Instance for writers
	}
```

- [ ] **Step 3: Statically verify + commit**

Run: `selene src` and `stylua --check src` (0 errors / clean).

```bash
git add src/Subagent.luau
git commit -m "feat(writers): thread writeRegion into the Subagent tool context"
```

---

## Task 4: system prompt — writer child + parent guidance

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Add `buildWriter` + `WRITER_BASE`**

After the `SUBAGENT_BASE` / `buildSubagent` definitions, add:

```lua
local WRITER_BASE = [[
You are a WRITER subagent operating inside Roblox Studio, dispatched by a parent build agent to build ONE part of the place. You are CONFINED to a single region of the DataModel (given below): you may ONLY create and edit instances INSIDE that region. You cannot run arbitrary Luau and cannot spawn other agents.

# Your tools
- create_instance(className, parent, name, properties): create + configure an instance via the engine API (no loadstring). `parent` MUST be your region root or a descendant of it.
- set_property(path, name, value): set ONE typed property on an instance inside your region. `value` is a structured JSON value (see "Value encoding").
- get_tree / search / get_properties / get_output / capture: read and inspect (you may READ anywhere, but only WRITE inside your region).
You do NOT have run_luau. Build everything with create_instance + set_property. To author a script, create_instance a "Script" / "LocalScript" / "ModuleScript" and set its "Source" property to your Luau as a string (build multi-line Source with "\n").

# Region confinement
Every instance you create or edit must be your region root or a descendant of it. A write outside your region is rejected. Build only what your task asks, inside your region.

# Value encoding (structured JSON values)
Pass these tagged shapes to set_property's `value` and create_instance's `properties`:
- Color3 -> {"__t":"Color3","r":..,"g":..,"b":..} (0..1); Vector3 -> {"__t":"Vector3","x":..,"y":..,"z":..}; Vector2 -> {"__t":"Vector2","x":..,"y":..}
- UDim2 -> {"__t":"UDim2","xs":..,"xo":..,"ys":..,"yo":..}; UDim -> {"__t":"UDim","s":..,"o":..}
- EnumItem -> {"__t":"EnumItem","enum":"Material","item":"Neon"}; CFrame -> {"__t":"CFrame","c":[..12 floats..]}
Plain strings/numbers/bools pass through as-is.

# Addressing instances
Case-sensitive, dot-separated paths from a top-level service, e.g. game.StarterGui.Shop.Frame.

# OUTPUT CONTRACT (critical)
Your FINAL message is your ENTIRE return value to the parent — it CANNOT see your tool calls or intermediate reasoning. Report TERSELY and COMPLETELY what you built: the instances you created (exact paths), key properties, and anything the parent needs for cross-region wiring. Do the build with your tools, then report.
]]

-- A writer-child system prompt: confined to `region`, building `task`.
function SystemPrompt.buildWriter(region: string, task: string): string
	return WRITER_BASE
		.. "\n# Your region (you may only WRITE here)\n"
		.. tostring(region)
		.. "\n\n# Your task\n"
		.. tostring(task)
		.. "\n"
end
```

- [ ] **Step 2: Add the parent tool line + "# Parallel building" section**

In `BASE`, after the `remember`/`forget` tool line, add:

```
- dispatch_writers(writers): build INDEPENDENT parts of the place IN PARALLEL via confined writer children — see "Parallel building".
```

In `BASE`, insert this section right after "# Fanning out subagents" and before "# Track multi-step work":

```
# Parallel building (go faster on big builds)
When a build has INDEPENDENT parts (e.g. a shop GUI, a lobby, an NPC), build them IN PARALLEL to go much faster. (1) Create the region CONTAINERS yourself first (a Folder/ScreenGui/Model for each part — they must EXIST before you dispatch). (2) Call dispatch_writers with one { region, task } per part; each child runs in parallel, CONFINED to its region, building with create_instance/set_property (it has NO run_luau and cannot nest). (3) When they return, do any cross-region wiring (references between parts) yourself and verify (capture / get_tree). Use this ONLY when the parts are genuinely independent and the build is large enough to be worth it; for a small or tightly-coupled build, just build it yourself.
```

- [ ] **Step 3: Statically verify + commit**

Run: `selene src` and `stylua --check src` (0 errors / clean).

```bash
git add src/SystemPrompt.luau
git commit -m "feat(writers): system prompt — buildWriter child + parent 'Parallel building'"
```

---

## Task 5: the `dispatch_writers` tool + register + spec

**Files:**
- Create: `src/Tools/Writers.luau`, `src/WritersSpec.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Implement `src/Tools/Writers.luau`**

```lua
--!strict
-- Writers: the dispatch_writers tool. Fans out PARALLEL WRITER children, each CONFINED to a region
-- subtree, to build independent parts of the place at once. The speedup is overlapping LLM round-trips
-- (the DataModel writes themselves are instant). Each child runs the Subagent loop with the structured
-- WRITE toolset + a region guard (context.writeRegion) — NO run_luau (can't be region-guarded) and NO
-- nesting (depth-1, enforced by the allowlist). Safe under Luau's cooperative scheduling because the
-- structured write tools are synchronous, so their ChangeHistory recordings are atomic (never overlap).
--
-- Tools/init requires this at load to register the tool; the Subagent runner, the Tools registry, and
-- Path are required LAZILY inside run() to avoid a module-load require cycle.

local HttpService = game:GetService("HttpService")
local SystemPrompt = require(script.Parent.Parent.SystemPrompt)

local Writers = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

-- Writer children get the structured WRITE tools + the read tools. NOT run_luau (arbitrary Luau can't
-- be region-guarded), NOT dispatch_* (depth-1).
local WRITE_TOOLS = {
	"create_instance",
	"set_property",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"capture",
}

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"writer result not JSON-encodable"}'
end

local function runDispatch(input: any, context: any): (string, boolean)
	local config = if type(context) == "table" then context.config else nil
	local anthropic = if type(context) == "table" then context.anthropic else nil
	if config == nil or anthropic == nil then
		return encodeResult({ ok = false, error = "dispatch_writers: missing config/anthropic" }), true
	end

	local args = if type(input) == "table" then input else {}
	local list = args.writers
	if type(list) ~= "table" or #list == 0 then
		return encodeResult({
			ok = false,
			error = "dispatch_writers requires { writers = [ { region, task }, ... ] } (at least 1)",
		}),
			true
	end

	-- Lazy requires break the Tools <- Writers <- Subagent <- Tools load-time cycle.
	local Tools = require(script.Parent)
	local Subagent = require(script.Parent.Parent.Subagent)
	local Path = require(script.Parent.Path)

	local cap = config:getWriterMaxParallel()
	local n = math.min(#list, cap)
	local dropped = #list - n

	local toolSchemas = (Tools :: any).schemasFor(WRITE_TOOLS)
	local allowed: { [string]: boolean } = {}
	for _, name in WRITE_TOOLS do
		allowed[name] = true
	end

	local model = config:getWriterModel()
	local maxIter = config:getWriterMaxIterations()
	local shouldCancel = if type(context) == "table" then context.shouldCancel else nil

	local results: { any } = {}
	local done = 0
	for i = 1, n do
		local w = list[i]
		local regionPath = if type(w) == "table" and type(w.region) == "string" then w.region else ""
		local taskPrompt = if type(w) == "table" and type(w.task) == "string" then w.task else ""
		task.spawn(function()
			-- Whole body pcall-wrapped (incl. region resolve + buildWriter + run) so `done` always
			-- increments and the join can't hang on a throw.
			local ok, res = pcall(function()
				local region, rerr = (Path :: any).resolve(regionPath)
				if region == nil then
					return {
						region = regionPath,
						ok = false,
						capped = false,
						text = "region not found: " .. tostring(rerr),
					}
				end
				local out = (Subagent :: any).run({
					anthropic = anthropic,
					config = config,
					systemPrompt = SystemPrompt.buildWriter(regionPath, taskPrompt),
					taskPrompt = taskPrompt,
					toolSchemas = toolSchemas,
					allowedTools = allowed,
					model = model,
					maxIterations = maxIter,
					shouldCancel = shouldCancel,
					writeRegion = region,
				})
				return { region = regionPath, ok = out.ok, capped = out.capped, text = out.text }
			end)
			if ok and type(res) == "table" then
				results[i] = res
			else
				results[i] = {
					region = regionPath,
					ok = false,
					capped = false,
					text = "writer error: " .. tostring(res),
				}
			end
			done += 1
		end)
	end

	-- Join. The parent loop is yielding here, so it is NOT writing -> quiescent for the children.
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

Writers.descriptors = {
	{
		name = "dispatch_writers",
		description = "Fan out PARALLEL WRITER subagents to build INDEPENDENT parts of the place at the "
			.. "same time — use this to go faster on a LARGE build with separable pieces. Each child is "
			.. "CONFINED to its `region` (a case-sensitive dot-path that must ALREADY EXIST — create the "
			.. "container instance first) and may ONLY create/edit instances inside it with "
			.. "create_instance/set_property (NO run_luau, NO nesting). Give each a self-contained "
			.. "`task` (it sees none of your chat). After they return, do any cross-region wiring "
			.. "yourself and verify. Don't use this for a small or tightly-coupled build — just build "
			.. "that yourself.",
		inputSchema = {
			type = "object",
			properties = {
				writers = {
					type = "array",
					description = "One or more writer children, each confined to its region, run in parallel.",
					items = {
						type = "object",
						properties = {
							region = {
								type = "string",
								description = "Existing dot-path the child is fenced to, e.g. 'game.StarterGui.Shop'.",
							},
							task = {
								type = "string",
								description = "Self-contained build task for this region (it sees none of your chat).",
							},
						},
						required = { "region", "task" },
					},
				},
			},
			required = { "writers" },
		},
		destructive = true,
		run = runDispatch,
	},
} :: { Descriptor }

return Writers
```

- [ ] **Step 2: Register in `src/Tools/init.luau`**

Add the require after `local MemoryTool = require(script.Memory)`:

```lua
local WritersTool = require(script.Writers)
```

Add the registration loop after the `MemoryTool.descriptors` loop:

```lua
for _, descriptor in WritersTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

Append `, dispatch_writers` to the registry-comment in the file header.

- [ ] **Step 3: Implement `src/WritersSpec.luau`**

```lua
--!strict
-- WritersSpec: in-Studio self-test for the PURE/structural pieces of dispatch_writers — the writer
-- toolset/allowlist and the RegionGuard. Run via temporarily adding `require(script.WritersSpec).run()`
-- to init.server.luau, build, reopen Studio, read Output.

local Tools = require(script.Parent.Tools)
local RegionGuard = require(script.Parent.Tools.RegionGuard)

local M = {}

local WRITE_TOOLS = {
	"create_instance",
	"set_property",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"capture",
}

local function allowedSet(): { [string]: boolean }
	local a: { [string]: boolean } = {}
	for _, n in WRITE_TOOLS do
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

	add("schemasFor returns exactly the writer toolset", function()
		local s = (Tools :: any).schemasFor(WRITE_TOOLS)
		if #s ~= #WRITE_TOOLS then
			return false, "got " .. tostring(#s) .. " schemas"
		end
		local names: { [string]: boolean } = {}
		for _, t in s do
			names[t.name] = true
		end
		for _, n in WRITE_TOOLS do
			if not names[n] then
				return false, "missing " .. n
			end
		end
		return true
	end)

	add("writer toolset excludes run_luau and dispatch tools", function()
		local s = (Tools :: any).schemasFor(WRITE_TOOLS)
		for _, t in s do
			if t.name == "run_luau" or t.name == "dispatch_subagents" or t.name == "dispatch_writers" then
				return false, "leaked " .. t.name
			end
		end
		return true
	end)

	add("dispatch allowlist rejects run_luau for a writer context", function()
		local _, isError = Tools.dispatch("run_luau", { code = "return 1" }, { allowedTools = allowedSet() })
		return isError == true
	end)

	add("dispatch allowlist rejects dispatch_writers (depth-1)", function()
		local _, isError =
			Tools.dispatch("dispatch_writers", { writers = {} }, { allowedTools = allowedSet() })
		return isError == true
	end)

	add("dispatch allowlist allows a read tool (get_tree)", function()
		local _, isError =
			Tools.dispatch("get_tree", { path = "game", depth = 0 }, { allowedTools = allowedSet() })
		return isError == false
	end)

	add("RegionGuard.within: region root, descendant, and outside", function()
		local region = Instance.new("Folder")
		local child = Instance.new("Part")
		child.Parent = region
		local outside = Instance.new("Part")
		local ok = RegionGuard.within(region, region) == true
			and RegionGuard.within(child, region) == true
			and RegionGuard.within(outside, region) == false
		region:Destroy()
		outside:Destroy()
		return ok
	end)

	add("RegionGuard.check: no region is a no-op; within passes; outside fails", function()
		local region = Instance.new("Folder")
		local child = Instance.new("Part")
		child.Parent = region
		local outside = Instance.new("Part")
		local noRegionOk = RegionGuard.check(outside, {}) == true -- no writeRegion -> allowed
		local withinOk = RegionGuard.check(child, { writeRegion = region }) == true
		local outsideOk, msg = RegionGuard.check(outside, { writeRegion = region })
		region:Destroy()
		outside:Destroy()
		return noRegionOk
			and withinOk
			and outsideOk == false
			and type(msg) == "string"
	end)

	add("dispatch_writers is total on bad input (no config)", function()
		local _, isError = Tools.dispatch("dispatch_writers", { writers = {} }, { config = nil })
		return isError == true
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== WritersSpec: running " .. tostring(total) .. " cases ===")
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

- [ ] **Step 4: Statically verify + commit**

Run: `selene src` and `stylua --check src` (0 errors / clean).

```bash
git add src/Tools/Writers.luau src/Tools/init.luau src/WritersSpec.luau
git commit -m "feat(writers): dispatch_writers tool + register + WritersSpec"
```

---

## Task 6: build, full lint, feature commit

**Files:** none (verification + build artifact)

- [ ] **Step 1: Full build**

Run: `.\build.ps1`
Expected: `rojo build` succeeds → `StudioAgent.rbxm` copied to the Plugins folder. No build errors.

- [ ] **Step 2: Full lint sweep**

Run: `selene src` (expect 0 errors; only the pre-existing `CreateDockWidgetPluginGui` warning) and `stylua --check src` (expect clean).

- [ ] **Step 3: (For the in-Studio run) temporarily enable the spec**

Temporarily add to `src/init.server.luau` near the end:

```lua
require(script.WritersSpec).run()
```

Build, reopen Studio (a NEW Baseplate per the test-session preference), read Output for `=== Summary: N/N passed ===`, then REMOVE that line and rebuild.

- [ ] **Step 4: Commit any final doc updates**

```bash
git add -A
git commit -m "build(writers): rebuild StudioAgent.rbxm with dispatch_writers"
```

---

## Self-Review (run after writing; fix inline)

**Spec coverage** — each spec decision maps to a task:
- `dispatch_writers` tool (region+task, cap, parallel) → Task 5. Regions-must-exist (resolve, error if missing) → Task 5 (`Path.resolve` per writer). Structured-tools-only / no run_luau / no nesting → Task 5 (`WRITE_TOOLS` + allowlist). Region guard incl. re-parent escape → Task 1. Reuse Subagent.run + `writeRegion` in context → Task 3 + Task 5. writerModel Sonnet + knobs → Task 2. buildWriter + parent section → Task 4. WritersSpec → Task 5. Build/lint → Task 6. ✓ no gaps.

**Type/name consistency** — `RegionGuard.within(target, region)` / `RegionGuard.check(target, context)`; `context.writeRegion`; `WRITE_TOOLS` (same list in Writers.luau + WritersSpec.luau); `dispatch_writers`; `writerModel`/`writerMaxParallel`/`writerMaxIterations` + their getters; `Subagent.run` opts gains `writeRegion`; `SystemPrompt.buildWriter(region, task)`; the `Descriptor.run` 2-arg signature in Create/Properties — all consistent across tasks. ✓

**Placeholder scan** — every code step shows complete code; no TBD/"handle edge cases"/"similar to". ✓

**Ordering note** — Task 4 (buildWriter) lands before Task 5 (Writers.run calls `SystemPrompt.buildWriter`); Tasks 2/3 (Config getters, Subagent.writeRegion) land before Task 5 uses them. The region guard (Task 1) is context-gated (no-op without `writeRegion`), so it ships safely before the writer path exists. Each task builds clean independently.
