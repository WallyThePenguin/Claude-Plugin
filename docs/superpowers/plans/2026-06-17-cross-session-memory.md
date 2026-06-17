# Cross-Session Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the in-Studio agent durable memory across chat sessions — a `Memory` store (two scopes: global + per-game) with `remember`/`forget` tools, always-on injection into the system prompt, and a panel viewer — mirroring Claude Code's memory files.

**Architecture:** A `Memory` module (held in `deps.memory`, persisted via `plugin:SetSetting`) owns two buckets keyed `StudioAgent_memory_global` and `StudioAgent_memory_game_<GameId>`; the `remember`/`forget` tools are thin wrappers over `context.memory`; `AgentLoop` threads `memory` into the tool context and composes the effective system prompt as `base .. memory:promptBlock()` each Send; the Widget adds a Memory viewer. Memory writes are durable and immediate — NOT rolled back with the conversation.

**Tech Stack:** Luau (`--!strict`), Rojo, selene, stylua. No new deps. Static verification: `selene src` (0 errors) + `stylua --check src` + `rojo build` via `.\build.ps1`. Logic tests are the in-Studio `MemorySpec`.

**Verification reality (from HANDOFF):** Luau using Roblox APIs can't run here. So "run the test" = the in-Studio `MemorySpec` the USER runs; in this session each task is statically verified with `selene src` (0 errors) + `stylua --check src`, and the whole feature builds with `.\build.ps1`. The PURE `Memory` helpers are covered by `MemorySpec`; scope-keying + persistence are verified live in Studio.

---

## File Structure

**Create:**
- `src/Memory.luau` — the store + pure helpers (`normalizeText`/`addTo`/`forgetFrom`/`renderBucket`) + instance methods (`add`/`forget`/`list`/`clear`/`promptBlock`/`loadBucket`). One instance in `deps.memory`.
- `src/MemorySpec.luau` — in-Studio self-test over the pure helpers.
- `src/Tools/Memory.luau` — the `remember` + `forget` tool descriptors (thin wrappers over `context.memory`).

**Modify:**
- `src/Tools/init.luau` — require + register `Memory.descriptors`.
- `src/AgentLoop.luau` — thread `memory` param → `toolContext`; compose `system = base .. memory:promptBlock()`.
- `src/init.server.luau` — require `Memory`; add `memory = Memory.new(plugin)` to `deps`.
- `src/UI/Widget.luau` — Memory viewer (toggle + list both buckets with per-entry `✕` forget); pass `deps.memory` to `send`; teach `clearScroller` + `layoutChecklist` about the memory view.
- `src/SystemPrompt.luau` — tool lines + "# Memory across sessions" section.

**Not changed (invariant called out, tested live):** `src/Tools/Subagents.luau` — `remember`/`forget` stay OUT of `READ_ONLY`.

---

## Task 1: `Memory` pure core + store + spec

**Files:**
- Create: `src/Memory.luau`
- Create: `src/MemorySpec.luau`

- [ ] **Step 1: Write the spec — `src/MemorySpec.luau`**

```lua
--!strict
-- MemorySpec: in-Studio self-test for the PURE Memory helpers (no DataModel, no SetSetting). Run via
-- temporarily adding `require(script.MemorySpec).run()` to init.server.luau, build, reopen Studio,
-- read Output.

local Memory = require(script.Parent.Memory)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalizeText trims and keeps a real string", function()
		return Memory.normalizeText("  hello  ") == "hello"
	end)

	add("normalizeText returns nil for empty / whitespace / non-string", function()
		return Memory.normalizeText("") == nil
			and Memory.normalizeText("   ") == nil
			and Memory.normalizeText(5) == nil
			and Memory.normalizeText(nil) == nil
			and Memory.normalizeText({}) == nil
	end)

	add("normalizeText truncates to MAX_TEXT codepoints (UTF-8 safe)", function()
		local long = string.rep("é", Memory.MAX_TEXT + 20)
		local out = Memory.normalizeText(long)
		return out ~= nil and utf8.len(out) == Memory.MAX_TEXT
	end)

	add("addTo appends with id = max+1, sets text + createdAt", function()
		local e1 = Memory.addTo({}, "first", 100)
		if #e1 ~= 1 or e1[1].id ~= 1 or e1[1].text ~= "first" or e1[1].createdAt ~= 100 then
			return false, "first add wrong"
		end
		local e2 = Memory.addTo(e1, "second", 200)
		return #e2 == 2 and e2[2].id == 2 and e2[2].text == "second"
	end)

	add("addTo rejects invalid text, leaving entries unchanged", function()
		local entries = Memory.addTo({}, "ok", 1)
		local after, note = Memory.addTo(entries, "   ", 2)
		return #after == 1 and string.find(note, "failed", 1, true) ~= nil
	end)

	add("addTo FIFO-drops the oldest past MAX_ENTRIES and reports it", function()
		local entries: { any } = {}
		for i = 1, Memory.MAX_ENTRIES do
			entries = Memory.addTo(entries, "t" .. i, i)
		end
		local after, note = Memory.addTo(entries, "overflow", 999)
		if #after ~= Memory.MAX_ENTRIES then
			return false, "kept " .. tostring(#after)
		end
		-- oldest (id 1) dropped; newest present; note mentions a drop
		return after[1].id == 2
			and after[#after].text == "overflow"
			and string.find(note, "dropped", 1, true) ~= nil
	end)

	add("addTo ids keep climbing after a FIFO drop", function()
		local entries: { any } = {}
		for i = 1, Memory.MAX_ENTRIES + 1 do
			entries = Memory.addTo(entries, "t" .. i, i)
		end
		-- after MAX_ENTRIES+1 adds, the last id is MAX_ENTRIES+1 (ids never reused)
		return entries[#entries].id == Memory.MAX_ENTRIES + 1
	end)

	add("forgetFrom removes by id (hit) and no-ops on a miss", function()
		local entries = Memory.addTo(Memory.addTo({}, "a", 1), "b", 2)
		local after, removed = Memory.forgetFrom(entries, 1)
		if not removed or #after ~= 1 or after[1].id ~= 2 then
			return false, "hit failed"
		end
		local after2, removed2 = Memory.forgetFrom(after, 99)
		return removed2 == false and #after2 == 1
	end)

	add("forgetFrom coerces a string id", function()
		local entries = Memory.addTo({}, "a", 1)
		local after, removed = Memory.forgetFrom(entries, "1")
		return removed == true and #after == 0
	end)

	add("renderBucket formats '#id text' and handles empty", function()
		if Memory.renderBucket({}) ~= "(none)" then
			return false, "empty render"
		end
		local entries = Memory.addTo(Memory.addTo({}, "alpha", 1), "beta", 2)
		local txt = Memory.renderBucket(entries)
		return string.find(txt, "#1 alpha", 1, true) ~= nil
			and string.find(txt, "#2 beta", 1, true) ~= nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== MemorySpec: running " .. tostring(total) .. " cases ===")
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

- [ ] **Step 2: Implement `src/Memory.luau`**

```lua
--!strict
-- Memory: cross-session memory the agent recalls automatically. Two scopes: "global" (one bucket,
-- carried across every place — the user's preferences + reusable techniques) and "game" (one bucket
-- per game.GameId — THIS place's architecture/conventions/decisions). Persisted via plugin:SetSetting
-- (same mechanism as Config/Sessions). The agent writes via the remember/forget tools; recall is
-- always-on injection (promptBlock appended to the system prompt each Send). One instance in deps.memory.
--
-- DURABLE: writes go straight to SetSetting and are NOT rolled back with the conversation on a
-- non-clean exit (unlike taskList). Memory rides in the SYSTEM prompt (not the message history), so
-- compaction never touches it.

local Memory = {}
Memory.__index = Memory

export type Entry = { id: number, text: string, createdAt: number }

local MAX_ENTRIES = 25
local MAX_TEXT = 240

Memory.MAX_ENTRIES = MAX_ENTRIES
Memory.MAX_TEXT = MAX_TEXT

local SETTING_PREFIX = "StudioAgent_"
local GLOBAL_KEY = SETTING_PREFIX .. "memory_global"

export type Memory = typeof(setmetatable(
	{} :: {
		_plugin: Plugin,
	},
	Memory
))

-- ---- pure helpers (no self, no DataModel — directly unit-testable) ----

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function truncate(s: string, maxChars: number): string
	local len = utf8.len(s)
	if len == nil then
		return string.sub(s, 1, maxChars)
	end
	if len <= maxChars then
		return s
	end
	local byteEnd = utf8.offset(s, maxChars + 1)
	if byteEnd == nil then
		return s
	end
	return string.sub(s, 1, byteEnd - 1)
end

-- Trim + UTF-8-safe truncate; nil if not a non-empty string.
function Memory.normalizeText(text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	local t = trim(text)
	if t == "" then
		return nil
	end
	return truncate(t, MAX_TEXT)
end

-- Append a normalized entry (id = max existing + 1, createdAt = now). FIFO-drop the oldest when over
-- MAX_ENTRIES. Returns (newEntries, note). Invalid text -> unchanged entries + an error note.
function Memory.addTo(entries: { Entry }, text: any, now: number): ({ Entry }, string)
	local normalized = Memory.normalizeText(text)
	if normalized == nil then
		return entries, "remember failed: text must be a non-empty string"
	end
	local maxId = 0
	for _, e in ipairs(entries) do
		if e.id > maxId then
			maxId = e.id
		end
	end
	local out: { Entry } = {}
	for _, e in ipairs(entries) do
		table.insert(out, e)
	end
	local newId = maxId + 1
	table.insert(out, { id = newId, text = normalized, createdAt = now })
	local dropped = 0
	while #out > MAX_ENTRIES do
		table.remove(out, 1)
		dropped += 1
	end
	local note = "remembered (#" .. tostring(newId) .. "); " .. tostring(#out) .. " stored"
	if dropped > 0 then
		note ..= "; dropped " .. tostring(dropped) .. " oldest (cap " .. tostring(MAX_ENTRIES) .. ")"
	end
	return out, note
end

-- Remove the entry with the given id (coerced to a number). Returns (newEntries, removed).
function Memory.forgetFrom(entries: { Entry }, id: any): ({ Entry }, boolean)
	local target = tonumber(id)
	local out: { Entry } = {}
	local removed = false
	for _, e in ipairs(entries) do
		if target ~= nil and e.id == target then
			removed = true
		else
			table.insert(out, e)
		end
	end
	return out, removed
end

-- Render a bucket as "#<id> <text>" lines, or "(none)".
function Memory.renderBucket(entries: { Entry }): string
	if #entries == 0 then
		return "(none)"
	end
	local lines: { string } = {}
	for _, e in ipairs(entries) do
		table.insert(lines, "#" .. tostring(e.id) .. " " .. e.text)
	end
	return table.concat(lines, "\n")
end

-- ---- instance (live store) ----

function Memory.new(plugin: Plugin): Memory
	return setmetatable({ _plugin = plugin }, Memory)
end

local function gameKey(): string
	return SETTING_PREFIX .. "memory_game_" .. tostring(game.GameId)
end

local function normScope(scope: any): string
	if scope == "global" then
		return "global"
	end
	return "game"
end

local function keyFor(scope: string): string
	if scope == "global" then
		return GLOBAL_KEY
	end
	return gameKey()
end

-- Load a bucket's entries, re-normalizing defensively (a corrupt/old blob can't inject junk).
function Memory.loadBucket(self: Memory, scope: string): { Entry }
	local raw = self._plugin:GetSetting(keyFor(scope))
	local out: { Entry } = {}
	if type(raw) == "table" then
		for _, e in ipairs(raw :: { any }) do
			if type(e) == "table" then
				local text = Memory.normalizeText(e.text)
				if text ~= nil and type(e.id) == "number" then
					table.insert(out, {
						id = e.id,
						text = text,
						createdAt = if type(e.createdAt) == "number" then e.createdAt else 0,
					})
				end
			end
		end
	end
	return out
end

-- Add a fact under scope ("global" or "game", default "game"). Persists. Returns a note.
function Memory.add(self: Memory, scope: any, text: any): string
	local s = normScope(scope)
	local entries = self:loadBucket(s)
	local updated, note = Memory.addTo(entries, text, os.time())
	self._plugin:SetSetting(keyFor(s), updated)
	return note .. " [" .. s .. "]"
end

-- Forget an entry by id under scope. Persists. Returns a confirmation.
function Memory.forget(self: Memory, scope: any, id: any): string
	local s = normScope(scope)
	local entries = self:loadBucket(s)
	local updated, removed = Memory.forgetFrom(entries, id)
	if not removed then
		return "no entry #" .. tostring(id) .. " in " .. s .. " memory"
	end
	self._plugin:SetSetting(keyFor(s), updated)
	return "forgot #" .. tostring(id) .. " [" .. s .. "]"
end

function Memory.list(self: Memory, scope: any): { Entry }
	return self:loadBucket(normScope(scope))
end

function Memory.clear(self: Memory, scope: any)
	self._plugin:SetSetting(keyFor(normScope(scope)), {})
end

-- Render BOTH buckets for injection into the system prompt. "" when both empty (inject nothing).
function Memory.promptBlock(self: Memory): string
	local g = self:loadBucket("global")
	local gm = self:loadBucket("game")
	if #g == 0 and #gm == 0 then
		return ""
	end
	return "# Remembered from earlier sessions\n"
		.. "Facts you saved in past chats (recalled automatically). Use forget(scope, id) to drop a stale one.\n\n"
		.. "## Global (every place)\n"
		.. Memory.renderBucket(g)
		.. "\n\n## This game\n"
		.. Memory.renderBucket(gm)
end

return Memory
```

- [ ] **Step 3: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: `selene` 0 errors (only the known `CreateDockWidgetPluginGui` warning); `stylua --check` clean (run `stylua src` first if it reports diffs).

- [ ] **Step 4: Commit**

```bash
git add src/Memory.luau src/MemorySpec.luau
git commit -m "feat(memory): Memory store + pure helpers + MemorySpec"
```

---

## Task 2: `remember` + `forget` tools + register

**Files:**
- Create: `src/Tools/Memory.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Implement `src/Tools/Memory.luau`**

```lua
--!strict
-- Memory tools: remember + forget. Thin wrappers over context.memory (the cross-session store).
-- Parent-only: NOT in the subagent allowlist, and a subagent context carries no memory, so they
-- no-op gracefully for a child (defence in depth).

local Memory = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function remember(input: any, context: any): (string, boolean)
	local mem = if type(context) == "table" then context.memory else nil
	if mem == nil then
		return "remember is not available here (no memory in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.text) ~= "string" then
		return "remember requires { text = <string>, scope? = 'game'|'global' }", true
	end
	return mem:add(args.scope, args.text), false
end

local function forget(input: any, context: any): (string, boolean)
	local mem = if type(context) == "table" then context.memory else nil
	if mem == nil then
		return "forget is not available here (no memory in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if args.id == nil then
		return "forget requires { scope = 'game'|'global', id = <number> }", true
	end
	return mem:forget(args.scope, args.id), false
end

Memory.descriptors = {
	{
		name = "remember",
		description = "Save a DURABLE fact to recall in FUTURE chats (it is injected into your context "
			.. "automatically next time). scope='game' (default) is for THIS place's architecture, "
			.. "conventions, and decisions; scope='global' is for your reusable techniques, Roblox "
			.. "gotchas, and the user's stated preferences (carried to every place). Keep each fact to "
			.. "one concise sentence. Don't save the obvious, the ephemeral, or anything already visible "
			.. "in the DataModel. Use forget to drop a fact that becomes wrong.",
		inputSchema = {
			type = "object",
			properties = {
				text = {
					type = "string",
					description = "The fact to remember (one concise sentence).",
				},
				scope = {
					type = "string",
					enum = { "game", "global" },
					description = "'game' (this place; default) or 'global' (every place).",
				},
			},
			required = { "text" },
		},
		destructive = false,
		run = remember,
	},
	{
		name = "forget",
		description = "Remove a remembered fact by its #id (shown in the injected memory list). Use "
			.. "when a fact is now wrong or obsolete.",
		inputSchema = {
			type = "object",
			properties = {
				scope = {
					type = "string",
					enum = { "game", "global" },
					description = "Which memory the entry is in.",
				},
				id = { type = "number", description = "The #id of the entry to forget." },
			},
			required = { "scope", "id" },
		},
		destructive = false,
		run = forget,
	},
} :: { Descriptor }

return Memory
```

- [ ] **Step 2: Register it in `src/Tools/init.luau`**

Add the require after `local TasksTool = require(script.Tasks)`:

```lua
local MemoryTool = require(script.Memory)
```

Add the registration loop after the `TasksTool.descriptors` loop:

```lua
for _, descriptor in MemoryTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

Update the registry-comment in the header to append `, remember, forget` to the final registry list.

- [ ] **Step 3: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Memory.luau src/Tools/init.luau
git commit -m "feat(memory): remember + forget tools + register in the Tools registry"
```

---

## Task 3: thread `memory` through `AgentLoop` + compose the system prompt

**Files:**
- Modify: `src/AgentLoop.luau`

- [ ] **Step 1: Add `memory` to `runLoop`'s signature**

Change `runLoop` (currently `runLoop(anthropic, config, systemPrompt, conversation, taskList, snapshot, cb)`) to insert `memory` after `taskList`:

```lua
local function runLoop(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	memory: any,
	snapshot: number,
	cb: Callbacks
)
```

- [ ] **Step 2: Add `memory` to the tool context and compose the effective system prompt**

Change the `toolContext`/`maxIter` region (currently):

```lua
	local messages = conversation.messages
	local tools = Tools.schemas()
	local maxIter = config:getMaxIterations()
	-- Dependencies a tool may need at run time (e.g. `capture` reads context.config for the sidecar;
	-- `update_tasks` mutates context.taskList — the in-panel checklist).
	local toolContext = { config = config, anthropic = anthropic, taskList = taskList }
```

to (adds `memory` to the context and builds `effectiveSystem` once per Send):

```lua
	local messages = conversation.messages
	local tools = Tools.schemas()
	local maxIter = config:getMaxIterations()
	-- Dependencies a tool may need at run time (e.g. `capture` reads context.config for the sidecar;
	-- `update_tasks` mutates context.taskList; `remember`/`forget` mutate context.memory).
	local toolContext =
		{ config = config, anthropic = anthropic, taskList = taskList, memory = memory }
	-- Compose the effective system prompt ONCE per Send: base + the recalled cross-session memory.
	-- Memory rides in the system prompt (not the message history), so compaction never strips it.
	local effectiveSystem = systemPrompt
	if memory ~= nil then
		local block = memory:promptBlock()
		if block ~= "" then
			effectiveSystem = (systemPrompt or "") .. "\n\n" .. block
		end
	end
```

- [ ] **Step 3: Send with the effective system prompt**

Change the `Retry.sendWithRetry` call (currently `system = systemPrompt`) to use `effectiveSystem`:

```lua
			res = Retry.sendWithRetry(
				anthropic,
				config,
				{ messages = messages, tools = tools, system = effectiveSystem },
				emit,
				cancelled
			)
```

- [ ] **Step 4: Add `memory` to `AgentLoop.send` and pass it into `runLoop`**

Change `AgentLoop.send` (currently `send(anthropic, config, systemPrompt, conversation, taskList, userText, cb)`) to insert `memory` after `taskList`:

```lua
function AgentLoop.send(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	memory: any,
	userText: string,
	cb: Callbacks
)
```

Change the `pcall(runLoop, ...)` call to pass `memory` (after `taskList`):

```lua
		local ok, err =
			pcall(runLoop, anthropic, config, systemPrompt, conversation, taskList, memory, snapshot, cb)
```

(No rollback handling for memory — it is durable by design; writes already persisted to SetSetting.)

- [ ] **Step 5: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 6: Commit**

```bash
git add src/AgentLoop.luau
git commit -m "feat(memory): thread memory into the tool context + inject it into the system prompt"
```

---

## Task 4: deps wiring

**Files:**
- Modify: `src/init.server.luau`

- [ ] **Step 1: Require `Memory` and add it to `deps`**

Add the require after `local TaskList = require(script.TaskList)`:

```lua
local Memory = require(script.Memory)
```

Add `memory` to the `deps` table (after `taskList`):

```lua
	taskList = TaskList.new(),
	memory = Memory.new(plugin),
}
```

- [ ] **Step 2: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 3: Commit**

```bash
git add src/init.server.luau
git commit -m "feat(memory): add memory store to deps"
```

---

## Task 5: the panel Memory viewer + wiring

**Files:**
- Modify: `src/UI/Widget.luau`

- [ ] **Step 1: Add `memory` to `Deps`**

In the `Deps` type, add (after `taskList: any,`):

```lua
	memory: any,
```

- [ ] **Step 2: Generalize `clearScroller` to destroy any GuiObject (so Frame rows clear too)**

Change `clearScroller` (currently destroys only `GuiButton`/`TextLabel`) to:

```lua
	local function clearScroller(sf: ScrollingFrame)
		for _, child in sf:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
```

(`UIListLayout`/`UIPadding` are not `GuiObject`, so they survive; the memory rows are `Frame`s, which are.)

- [ ] **Step 3: Create the memory scroller and add the Memory button to the control row**

After `local sessionList = scroller()` / `sessionList.Visible = false`, add the memory scroller:

```lua
	local memoryList = scroller()
	memoryList.Visible = false
```

In the control-row setup, move the `status` label right and insert a Memory button. Replace the `status` block (currently `status.Size = UDim2.new(1, -158, 0, 26)` / `status.Position = UDim2.fromOffset(158, 64)`) — first add the button just before `status` is created:

```lua
	local memBtn = button("Memory")
	memBtn.Size = UDim2.fromOffset(66, 26)
	memBtn.Position = UDim2.fromOffset(158, 64)
	memBtn.Parent = root
```

Then change the two `status` lines to:

```lua
	status.Size = UDim2.new(1, -230, 0, 26)
	status.Position = UDim2.fromOffset(230, 64)
```

- [ ] **Step 4: Teach `layoutChecklist` about the memory view**

In `layoutChecklist`, change the `show` computation (currently `local show = n > 0 and not sessionList.Visible`) to also hide the checklist while the memory view is open:

```lua
		local show = n > 0 and not sessionList.Visible and not memoryList.Visible
```

- [ ] **Step 5: Add the memory render + view-toggle functions**

Place this block AFTER `refreshSessions` is defined (so `clearScroller`/`layoutChecklist`/`status` are in scope) and BEFORE the "Wiring" section. Note the forward declaration so a row's `✕` callback can call `refreshMemory`:

```lua
	-- Memory view -------------------------------------------------------------------------------
	local refreshMemory: () -> ()

	local function addMemLabel(text: string, color: Color3, size: number)
		rowOrder += 1
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -8, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextColor3 = color
		label.TextSize = size
		label.Font = Enum.Font.GothamBold
		label.Text = text
		label.LayoutOrder = rowOrder
		label.Parent = memoryList
	end

	local function addMemRow(scope: string, entry: any)
		rowOrder += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -8, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.LayoutOrder = rowOrder
		row.Parent = memoryList
		local txt = Instance.new("TextLabel")
		txt.BackgroundTransparency = 1
		txt.Size = UDim2.new(1, -26, 0, 0)
		txt.AutomaticSize = Enum.AutomaticSize.Y
		txt.TextWrapped = true
		txt.TextXAlignment = Enum.TextXAlignment.Left
		txt.TextYAlignment = Enum.TextYAlignment.Top
		txt.TextColor3 = TEXT
		txt.TextSize = 13
		txt.Font = Enum.Font.Gotham
		txt.Text = "#" .. tostring(entry.id) .. "  " .. tostring(entry.text)
		txt.Parent = row
		local x = button("✕")
		x.Size = UDim2.fromOffset(22, 22)
		x.Position = UDim2.new(1, -22, 0, 0)
		x.Parent = row
		x.Activated:Connect(function()
			deps.memory:forget(scope, entry.id)
			refreshMemory()
		end)
	end

	function refreshMemory()
		clearScroller(memoryList)
		rowOrder = 0
		addMemLabel("GLOBAL (every place)", MUTED, 12)
		local g = deps.memory:list("global")
		if #g == 0 then
			addMemLabel("  (none)", MUTED, 12)
		else
			for _, e in g do
				addMemRow("global", e)
			end
		end
		addMemLabel("THIS GAME", MUTED, 12)
		local gm = deps.memory:list("game")
		if #gm == 0 then
			addMemLabel("  (none)", MUTED, 12)
		else
			for _, e in gm do
				addMemRow("game", e)
			end
		end
	end
```

- [ ] **Step 6: Make the view toggles mutually exclusive (History ↔ Memory ↔ transcript)**

Replace the existing `showSessions` function (currently sets `sessionList.Visible`/`transcript.Visible`/`histBtn.Text`/`layoutChecklist()`) with a shared `updateViews` plus thin `showSessions`/`showMemory`:

```lua
	local function updateViews()
		transcript.Visible = not (sessionList.Visible or memoryList.Visible)
		histBtn.Text = if sessionList.Visible then "Back" else "History"
		memBtn.Text = if memoryList.Visible then "Back" else "Memory"
		layoutChecklist()
	end

	local function showSessions(show: boolean)
		sessionList.Visible = show
		if show then
			memoryList.Visible = false
		end
		updateViews()
	end

	local function showMemory(show: boolean)
		memoryList.Visible = show
		if show then
			sessionList.Visible = false
			refreshMemory()
		end
		updateViews()
	end
```

(`showSessions` keeps the same signature, so `openSession`/`newBtn`/`sendBtn` callers are unchanged.)

- [ ] **Step 7: Wire the Memory button**

In the "Wiring" section, next to the `histBtn.Activated` handler, add:

```lua
	memBtn.Activated:Connect(function()
		showMemory(not memoryList.Visible)
	end)
```

- [ ] **Step 8: Pass `deps.memory` to `agentLoop.send`**

In `sendBtn.Activated`, change the `deps.agentLoop.send(...)` call to pass `deps.memory` after `deps.taskList`:

```lua
		deps.agentLoop.send(
			deps.anthropic,
			deps.config,
			deps.systemPrompt,
			deps.conversation,
			deps.taskList,
			deps.memory,
			text,
			{
```

- [ ] **Step 9: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean. (If `selene` flags `refreshMemory` as "shadowing"/unused, it won't — it's a forward-declared upvalue assigned by `function refreshMemory()`.)

- [ ] **Step 10: Commit**

```bash
git add src/UI/Widget.luau
git commit -m "feat(memory): panel Memory viewer (both scopes, per-entry forget) + wiring"
```

---

## Task 6: system prompt guidance

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Add the tool lines to the tools list**

In `BASE`, after the `update_tasks(tasks)` bullet, add:

```
- remember(text, scope?) / forget(scope, id): save or drop DURABLE facts that you recall in FUTURE chats — see "Memory across sessions".
```

- [ ] **Step 2: Add the "Memory across sessions" section**

In `BASE`, insert this section right after the "# Track multi-step work" section and before "# Working rules":

```
# Memory across sessions
Any facts under "Remembered from earlier sessions" in your context were saved by YOU in past chats and are recalled automatically. There are two scopes: GLOBAL (applies in every place) and THIS GAME (this place only). Call remember(text, scope) to save a DURABLE fact worth recalling later: this game's architecture, conventions, or decisions -> scope="game" (the default); your reusable build techniques, Roblox gotchas, and the user's stated preferences -> scope="global". Keep each fact to ONE concise sentence. Do NOT remember the obvious, the ephemeral (one-off task details), or anything you can just re-read from the DataModel — and don't re-save a fact that's already listed. Use forget(scope, id) to drop a fact that has become wrong.
```

- [ ] **Step 3: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(memory): document remember/forget + cross-session memory in the system prompt"
```

---

## Task 7: build, full lint, and feature commit

**Files:** none (verification + build artifact)

- [ ] **Step 1: Full build**

Run: `.\build.ps1`
Expected: `rojo build` succeeds → `StudioAgent.rbxm` copied to the Plugins folder. No build errors.

- [ ] **Step 2: Full lint sweep**

Run: `selene src` (expect 0 errors; only the pre-existing `CreateDockWidgetPluginGui` warning) and `stylua --check src` (expect clean).

- [ ] **Step 3: (For the in-Studio run) temporarily enable the spec**

Temporarily add to `src/init.server.luau` near the end:

```lua
require(script.MemorySpec).run()
```

Build, have the user reopen Studio, read Output for `=== Summary: N/N passed ===`, then REMOVE that line and rebuild (the spec is not shipped enabled, matching the other Specs).

- [ ] **Step 4: Commit any final doc updates**

```bash
git add -A
git commit -m "build(memory): rebuild StudioAgent.rbxm with cross-session memory"
```

---

## Self-Review (run after writing; fix inline)

**Spec coverage** — each spec decision maps to a task:
- Two scopes (global + per-GameId) → Task 1 (`gameKey`/`keyFor`/`normScope`). Always-on injection → Task 3 (`promptBlock` composition). remember/forget tools, parent-only → Task 2 (+ not added to `READ_ONLY`; nil-memory guard in `run`). Durable, not rolled back → Task 3 (no rollback handling — explicit). FIFO caps + reported → Task 1 (`addTo`). Memory viewer (both buckets, per-entry forget) → Task 5. System prompt → Task 6. Pure self-test → Task 1 (`MemorySpec`). Build/lint → Task 7. ✓ no gaps.

**Type/name consistency** — `Memory.new/normalizeText/addTo/forgetFrom/renderBucket/loadBucket/add/forget/list/clear/promptBlock`, `MAX_ENTRIES`/`MAX_TEXT`, `Entry = {id,text,createdAt}`, `memory` (deps + context + params), `remember`/`forget` (tool names), scopes `"global"`/`"game"`, Widget `memoryList`/`memBtn`/`refreshMemory`/`addMemRow`/`addMemLabel`/`showMemory`/`updateViews`, `clearScroller` (now GuiObject) — all consistent across tasks. ✓

**Placeholder scan** — every code step shows complete code; no TBD/"handle edge cases"/"similar to". ✓

**Ordering note** — `AgentLoop.send`/`runLoop` get the new `memory` param BEFORE the Widget caller passes it (Task 3 before Task 5), but the param is positional and only the Widget calls `send`; until Task 5 lands, `send` would receive `userText` in the `memory` slot — so Tasks 3 and 5 must land together before a build is run. Both are committed before the Task 7 build, so no broken intermediate build is shipped. (Subagents call `Retry`/`Subagent.run` directly, never `AgentLoop.send`, so they're unaffected.)
```
