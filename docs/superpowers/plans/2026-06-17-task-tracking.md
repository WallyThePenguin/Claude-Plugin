# Task Tracking (`update_tasks`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the in-Studio agent a visible, self-maintained multi-step build checklist in the panel (a `update_tasks` tool + a `TaskList` state object + a collapsible panel section), mirroring Claude Code's `TodoWrite`.

**Architecture:** A pure `TaskList` state module (held in `deps`, outside the message history so it survives re-mount and compaction) owns the checklist; the `update_tasks` tool is a thin wrapper that calls `context.taskList:set(input)`; `AgentLoop` threads the list into the tool context and emits `tasks` to the UI after a batch that ran the tool; the Widget renders a reflowing, collapsible checklist; Sessions persists it per chat.

**Tech Stack:** Luau (`--!strict`), Rojo, selene, stylua. No new external deps. Tests are in-Studio Spec modules (run by the user); static verification is `selene src` (0 errors) + `stylua --check src` + `rojo build` via `.\build.ps1`.

**Verification reality (from HANDOFF):** Luau using Roblox APIs cannot run here. So "run the test" = the in-Studio `TaskListSpec` the USER runs; in this session each task is statically verified with `selene src` (0 errors) + `stylua --check src`, and the whole feature builds with `.\build.ps1`. The pure `TaskList` logic is fully covered by `TaskListSpec`.

---

## File Structure

**Create:**
- `src/TaskList.luau` — checklist state + PURE normalization/validation/render/counts shared by the tool and the spec. One instance in `deps.taskList`.
- `src/TaskListSpec.luau` — in-Studio self-test over the pure `TaskList` surface (mirrors `WebSpec`/`SubagentsSpec`).
- `src/Tools/Tasks.luau` — the `update_tasks` tool descriptor (thin wrapper over `context.taskList`).

**Modify:**
- `src/Tools/init.luau` — require + register `Tasks.descriptors`.
- `src/AgentLoop.luau` — thread `taskList` param → `toolContext`; emit `tasks` after an `update_tasks` batch.
- `src/init.server.luau` — require `TaskList`; add `taskList = TaskList.new()` to `deps`.
- `src/Sessions.luau` — `save(conversation, id, tasks)` persists the array; `load` returns `tasks`.
- `src/UI/Widget.luau` — checklist render + reflow + lifecycle wiring; pass `taskList` to `send`.
- `src/SystemPrompt.luau` — tool line + "Track multi-step work" section.

**Not changed (invariant called out, tested in the Spec):** `src/Tools/Subagents.luau` — `update_tasks` stays OUT of `READ_ONLY`.

---

## Task 1: `TaskList` pure core + spec

**Files:**
- Create: `src/TaskList.luau`
- Create: `src/TaskListSpec.luau`

- [ ] **Step 1: Write the spec (the failing test) — `src/TaskListSpec.luau`**

```lua
--!strict
-- TaskListSpec: in-Studio self-test for the PURE TaskList surface (no DataModel, no network). Run via
-- temporarily adding `require(script.TaskListSpec).run()` to init.server.luau, build, reopen Studio,
-- read Output.

local TaskList = require(script.Parent.TaskList)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalize parses {tasks=[...]} keeping valid statuses + order", function()
		local out = TaskList.normalize({
			tasks = {
				{ content = "a", status = "completed" },
				{ content = "b", status = "in_progress" },
				{ content = "c", status = "pending" },
			},
		})
		if #out ~= 3 then
			return false, "got " .. tostring(#out)
		end
		return out[1].status == "completed"
			and out[2].status == "in_progress"
			and out[3].content == "c"
	end)

	add("normalize coerces missing/unknown status to pending", function()
		local out = TaskList.normalize({
			tasks = { { content = "a" }, { content = "b", status = "bogus" } },
		})
		return out[1].status == "pending" and out[2].status == "pending"
	end)

	add("normalize drops empty / whitespace-only content", function()
		local out = TaskList.normalize({
			tasks = { { content = "  " }, { content = "" }, { content = "real" } },
		})
		return #out == 1 and out[1].content == "real"
	end)

	add("normalize drops non-table items", function()
		local out = TaskList.normalize({ tasks = { "nope", 5, { content = "ok" } } })
		return #out == 1 and out[1].content == "ok"
	end)

	add("normalize truncates content to MAX_CONTENT codepoints", function()
		local long = string.rep("x", TaskList.MAX_CONTENT + 50)
		local out = TaskList.normalize({ tasks = { { content = long, status = "pending" } } })
		return #out == 1 and #out[1].content == TaskList.MAX_CONTENT
	end)

	add("normalize caps at MAX_TASKS and reports dropped", function()
		local items = {}
		for i = 1, TaskList.MAX_TASKS + 5 do
			items[i] = { content = "t" .. i, status = "pending" }
		end
		local out, summary = TaskList.normalize({ tasks = items })
		if #out ~= TaskList.MAX_TASKS then
			return false, "kept " .. tostring(#out)
		end
		return string.find(summary, "dropped", 1, true) ~= nil
	end)

	add("normalize tolerates a bare array", function()
		local out = TaskList.normalize({ { content = "a", status = "pending" } })
		return #out == 1 and out[1].content == "a"
	end)

	add("normalize on non-table input returns empty (no throw)", function()
		local out = TaskList.normalize("garbage")
		return #out == 0
	end)

	add("counts computes done / in_progress / pending", function()
		local c = TaskList.counts({
			{ content = "a", status = "completed" },
			{ content = "b", status = "completed" },
			{ content = "c", status = "in_progress" },
			{ content = "d", status = "pending" },
		})
		return c.total == 4 and c.completed == 2 and c.inProgress == 1 and c.pending == 1
	end)

	add("set replaces in place + snapshot is isolated", function()
		local tl = TaskList.new()
		tl:set({ tasks = { { content = "a", status = "pending" } } })
		local snap = tl:snapshot()
		snap[1].status = "completed" -- mutate the snapshot
		-- A later set must not be visible in the OLD snapshot, and the snapshot mutation must not
		-- have leaked into the live list.
		if tl:snapshot()[1].status ~= "pending" then
			return false, "snapshot mutation leaked into the live list"
		end
		tl:set({ tasks = {} })
		return #snap == 1 and #tl:snapshot() == 0
	end)

	add("clear empties the list", function()
		local tl = TaskList.new()
		tl:set({ tasks = { { content = "a", status = "pending" } } })
		tl:clear()
		return #tl:snapshot() == 0
	end)

	add("load re-normalizes a persisted array (defensive)", function()
		local tl = TaskList.new()
		tl:load({ { content = "good", status = "weird" }, { content = "" }, "junk" })
		local snap = tl:snapshot()
		return #snap == 1 and snap[1].content == "good" and snap[1].status == "pending"
	end)

	add("render formats a numbered, tagged list and handles empty", function()
		if TaskList.render({}) ~= "(no tasks)" then
			return false, "empty render"
		end
		local txt = TaskList.render({
			{ content = "build", status = "in_progress" },
			{ content = "wire", status = "pending" },
		})
		return string.find(txt, "1. [in_progress] build", 1, true) ~= nil
			and string.find(txt, "2. [pending] wire", 1, true) ~= nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== TaskListSpec: running " .. tostring(total) .. " cases ===")
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

- [ ] **Step 2: Implement `src/TaskList.luau`**

```lua
--!strict
-- TaskList: the in-panel build checklist state + the PURE normalization the update_tasks tool and
-- TaskListSpec share. ONE instance lives in deps.taskList (alongside the conversation), so it survives
-- the panel re-mount on a Play/Edit transition AND lives OUTSIDE the Anthropic message history, so
-- context compaction never strips it. Declarative full-list-replace (mirrors TodoWrite): set() takes
-- the WHOLE list every call.

local TaskList = {}
TaskList.__index = TaskList

export type Status = "pending" | "in_progress" | "completed"
export type Task = { content: string, status: Status }

local MAX_CONTENT = 200
local MAX_TASKS = 50

TaskList.MAX_CONTENT = MAX_CONTENT
TaskList.MAX_TASKS = MAX_TASKS

export type TaskList = typeof(setmetatable(
	{} :: {
		tasks: { Task },
	},
	TaskList
))

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Truncate to maxChars CODEPOINTS on a UTF-8 boundary, so a cut never splits a multi-byte char into
-- invalid UTF-8 (which could later break JSONEncode of the snapshot / tool_result).
local function truncate(s: string, maxChars: number): string
	local len = utf8.len(s)
	if len == nil then
		return string.sub(s, 1, maxChars) -- not valid UTF-8: byte fallback
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

local function normStatus(raw: any): Status
	if type(raw) == "string" then
		local s = string.lower(trim(raw))
		if s == "in_progress" or s == "completed" then
			return s :: Status
		end
	end
	return "pending"
end

-- Normalize one raw item into a Task, or nil if it can't be a valid task.
local function normalizeOne(item: any): Task?
	if type(item) ~= "table" then
		return nil
	end
	local rawContent = item.content
	local content = if type(rawContent) == "string" then rawContent else tostring(rawContent)
	content = trim(content)
	if content == "" then
		return nil
	end
	content = truncate(content, MAX_CONTENT)
	return { content = content, status = normStatus(item.status) }
end

-- Tally statuses (used by the tool summary and the panel header).
function TaskList.counts(
	tasks: { Task }
): { total: number, completed: number, inProgress: number, pending: number }
	local total, completed, inProgress, pending = 0, 0, 0, 0
	for _, t in ipairs(tasks) do
		total += 1
		if t.status == "completed" then
			completed += 1
		elseif t.status == "in_progress" then
			inProgress += 1
		else
			pending += 1
		end
	end
	return { total = total, completed = completed, inProgress = inProgress, pending = pending }
end

-- PURE. Accepts either { tasks = {...} } or a bare array (tolerant), returns the normalized task array
-- plus a one-line summary the model re-reads in its tool_result.
function TaskList.normalize(input: any): ({ Task }, string)
	local raw: { any }
	if type(input) == "table" and type((input :: any).tasks) == "table" then
		raw = (input :: any).tasks
	elseif type(input) == "table" then
		raw = input :: { any }
	else
		raw = {}
	end

	local out: { Task } = {}
	local dropped = 0
	for _, item in ipairs(raw) do
		if #out >= MAX_TASKS then
			dropped += 1
		else
			local task = normalizeOne(item)
			if task ~= nil then
				table.insert(out, task)
			end
		end
	end

	local c = TaskList.counts(out)
	local summary = string.format(
		"tasks updated: %d total (%d done, %d in progress, %d pending)",
		c.total,
		c.completed,
		c.inProgress,
		c.pending
	)
	if dropped > 0 then
		summary ..= string.format("; %d dropped (cap %d)", dropped, MAX_TASKS)
	end
	return out, summary
end

-- Compact numbered render for the tool_result, so the model re-reads the exact accepted state.
function TaskList.render(tasks: { Task }): string
	if #tasks == 0 then
		return "(no tasks)"
	end
	local lines: { string } = {}
	for i, t in ipairs(tasks) do
		table.insert(lines, string.format("%d. [%s] %s", i, t.status, t.content))
	end
	return table.concat(lines, "\n")
end

function TaskList.new(): TaskList
	return setmetatable({ tasks = {} }, TaskList)
end

-- Normalize + replace IN PLACE (refs to .tasks stay valid, mirroring Conversation.replaceMessages).
-- Returns the summary string.
function TaskList.set(self: TaskList, input: any): string
	local normalized, summary = TaskList.normalize(input)
	table.clear(self.tasks)
	for _, t in ipairs(normalized) do
		table.insert(self.tasks, t)
	end
	return summary
end

-- A fresh per-task copy for the UI event / session save (a plain, JSON-safe array; isolated from the
-- live list so a later set() can't mutate an already-emitted/saved snapshot).
function TaskList.snapshot(self: TaskList): { Task }
	local out: { Task } = {}
	for _, t in ipairs(self.tasks) do
		table.insert(out, { content = t.content, status = t.status })
	end
	return out
end

-- Replace from a persisted array; re-normalize defensively so an old/corrupt blob can't inject junk.
function TaskList.load(self: TaskList, tasks: any)
	self:set({ tasks = tasks })
end

function TaskList.clear(self: TaskList)
	table.clear(self.tasks)
end

return TaskList
```

- [ ] **Step 3: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: `selene` 0 errors (the lone known `CreateDockWidgetPluginGui` warning is unrelated); `stylua --check` clean (run `stylua src` first if it reports diffs).

- [ ] **Step 4: Commit**

```bash
git add src/TaskList.luau src/TaskListSpec.luau
git commit -m "feat(tasks): TaskList state + pure normalize/render/counts + TaskListSpec"
```

---

## Task 2: `update_tasks` tool + register it

**Files:**
- Create: `src/Tools/Tasks.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Implement `src/Tools/Tasks.luau`**

```lua
--!strict
-- Tasks: the update_tasks tool. The agent maintains a VISIBLE build checklist in the panel by sending
-- the WHOLE list every call (declarative replace, like TodoWrite). The tool is a thin wrapper over the
-- TaskList state held in context.taskList; the agent loop emits the new snapshot to the UI after a
-- batch that ran this tool. Parent-only: it is NOT in the subagent allowlist, and a subagent context
-- carries no taskList, so it no-ops gracefully for a child (defence in depth).

local TaskList = require(script.Parent.Parent.TaskList)

local Tasks = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function run(input: any, context: any): (string, boolean)
	local taskList = if type(context) == "table" then context.taskList else nil
	if taskList == nil then
		return "update_tasks is not available here (no checklist in this context)", true
	end
	local summary = taskList:set(input)
	local listText = TaskList.render(taskList:snapshot())
	return listText .. "\n" .. summary, false
end

Tasks.descriptors = {
	{
		name = "update_tasks",
		description = "Maintain a VISIBLE build checklist shown to the user in the panel. Send the "
			.. "ENTIRE task list every call (declarative replace, NOT incremental): pass `tasks` as the "
			.. "full ordered list, each { content, status } where status is 'pending', 'in_progress', "
			.. "or 'completed'. Use this for any build of ~3+ steps so the user sees your plan and live "
			.. "progress; skip it for a trivial single step. Mark exactly ONE task 'in_progress' at a "
			.. "time and flip a task to 'completed' the moment its step is done (don't batch). Sending "
			.. "an empty list clears the checklist. This is a visibility aid — it does NOT build "
			.. "anything; you still do the work with the other tools.",
		inputSchema = {
			type = "object",
			properties = {
				tasks = {
					type = "array",
					description = "The full ordered checklist (send ALL tasks every call).",
					items = {
						type = "object",
						properties = {
							content = {
								type = "string",
								description = "Short, outcome-shaped step, e.g. 'Build the inventory grid'.",
							},
							status = {
								type = "string",
								enum = { "pending", "in_progress", "completed" },
								description = "One of pending, in_progress, completed.",
							},
						},
						required = { "content", "status" },
					},
				},
			},
			required = { "tasks" },
		},
		destructive = false,
		run = run,
	},
} :: { Descriptor }

return Tasks
```

- [ ] **Step 2: Register it in `src/Tools/init.luau`**

Add the require alongside the others (after `local SubagentsTool = require(script.Subagents)`):

```lua
local TasksTool = require(script.Tasks)
```

Add the registration loop after the `SubagentsTool.descriptors` loop:

```lua
for _, descriptor in TasksTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

Update the registry-comment in the file header (line ~10-12) to mention `update_tasks` in the final registry list (cosmetic, keep the doc honest).

- [ ] **Step 3: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Tasks.luau src/Tools/init.luau
git commit -m "feat(tasks): update_tasks tool + register in the Tools registry"
```

---

## Task 3: thread `taskList` through `AgentLoop` + emit `tasks`

**Files:**
- Modify: `src/AgentLoop.luau`

- [ ] **Step 1: Add `taskList` to `runLoop`'s signature and the tool context**

Change the `runLoop` signature (currently `runLoop(anthropic, config, systemPrompt, conversation, snapshot, cb)`) to insert `taskList` after `conversation`:

```lua
local function runLoop(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	snapshot: number,
	cb: Callbacks
)
```

Change the `toolContext` line (currently `local toolContext = { config = config, anthropic = anthropic }`) to:

```lua
	-- Dependencies a tool may need at run time (e.g. `capture` reads context.config for the sidecar;
	-- `update_tasks` mutates context.taskList — the in-panel checklist).
	local toolContext = { config = config, anthropic = anthropic, taskList = taskList }
```

- [ ] **Step 2: Emit `tasks` after a batch that ran `update_tasks`**

In the `else` branch where tool_uses are dispatched, track whether `update_tasks` ran and emit the new snapshot after the assistant + tool_result messages are appended. The block currently reads:

```lua
			local toolResults: { any } = {}
			for _, block in ipairs(toolUses) do
				emit("tool_use", { name = block.name })
				local content, isError = Tools.dispatch(block.name, block.input, toolContext)
				-- content is a string (most tools) OR a tool_result blocks array (capture's image).
				-- Keep the empty-string guard for text; pass a blocks array straight through.
				if type(content) == "string" and content == "" then
					content = "(no output)"
				end
				local display = if type(content) == "string" then content else "[image]"
				emit("tool_result", { name = block.name, isError = isError, text = display })
				table.insert(toolResults, {
					type = "tool_result",
					tool_use_id = block.id,
					content = content,
					is_error = isError,
				})
			end
			table.insert(messages, { role = "assistant", content = data.content })
			table.insert(messages, { role = "user", content = toolResults })
```

Replace it with (adds `tasksChanged` tracking + the emit):

```lua
			local toolResults: { any } = {}
			local tasksChanged = false
			for _, block in ipairs(toolUses) do
				emit("tool_use", { name = block.name })
				local content, isError = Tools.dispatch(block.name, block.input, toolContext)
				-- content is a string (most tools) OR a tool_result blocks array (capture's image).
				-- Keep the empty-string guard for text; pass a blocks array straight through.
				if type(content) == "string" and content == "" then
					content = "(no output)"
				end
				local display = if type(content) == "string" then content else "[image]"
				emit("tool_result", { name = block.name, isError = isError, text = display })
				table.insert(toolResults, {
					type = "tool_result",
					tool_use_id = block.id,
					content = content,
					is_error = isError,
				})
				if block.name == "update_tasks" then
					tasksChanged = true
				end
			end
			table.insert(messages, { role = "assistant", content = data.content })
			table.insert(messages, { role = "user", content = toolResults })
			-- Reflect the new checklist to the panel (the tool already mutated taskList in place).
			if tasksChanged and taskList ~= nil then
				emit("tasks", taskList:snapshot())
			end
```

- [ ] **Step 3: Add `taskList` to `AgentLoop.send` and pass it into `runLoop`**

Change `AgentLoop.send`'s signature (currently `send(anthropic, config, systemPrompt, conversation, userText, cb)`) to insert `taskList` after `conversation`:

```lua
function AgentLoop.send(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	userText: string,
	cb: Callbacks
)
```

Change the `pcall(runLoop, ...)` call (inside the `task.spawn`) to pass `taskList`:

```lua
		local ok, err = pcall(runLoop, anthropic, config, systemPrompt, conversation, taskList, snapshot, cb)
```

- [ ] **Step 4: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 5: Commit**

```bash
git add src/AgentLoop.luau
git commit -m "feat(tasks): thread taskList through AgentLoop + emit tasks after update_tasks"
```

---

## Task 4: deps wiring + session persistence

**Files:**
- Modify: `src/init.server.luau`
- Modify: `src/Sessions.luau`

- [ ] **Step 1: Add `TaskList` to `deps` in `src/init.server.luau`**

Add the require alongside the others (after `local Sessions = require(script.Sessions)`):

```lua
local TaskList = require(script.TaskList)
```

Add `taskList` to the `deps` table:

```lua
local deps = {
	config = config,
	anthropic = anthropic,
	agentLoop = AgentLoop,
	systemPrompt = SystemPrompt.build(),
	conversation = Conversation.new(),
	sessions = Sessions.new(plugin),
	taskList = TaskList.new(),
}
```

- [ ] **Step 2: Persist + load the checklist in `src/Sessions.luau`**

Change `Sessions.save` to accept and store a `tasks` array. Current signature `save(self, conversation, id)`; new:

```lua
-- Persist a conversation under `id` and move it to the front of the index. No-op for an empty chat.
-- `tasks` is the conversation's checklist (taskList:snapshot()) — a plain JSON-safe array; defaults to
-- empty so an older caller / empty checklist persists cleanly.
function Sessions.save(self: Sessions, conversation: any, id: string, tasks: { any }?)
	if #conversation.messages == 0 then
		return
	end
	local title = if conversation.title ~= "" then conversation.title else "(untitled)"
	local updatedAt = os.time()

	self._plugin:SetSetting(SESSION_PREFIX .. id, {
		id = id,
		title = title,
		updatedAt = updatedAt,
		messages = MessageUtil.stripImages(conversation.messages),
		tasks = tasks or {},
	})

	local index = readIndex(self)
	local rebuilt: { Meta } = { { id = id, title = title, updatedAt = updatedAt } }
	for _, meta in index do
		if meta.id ~= id then
			table.insert(rebuilt, meta)
		end
	end
	while #rebuilt > MAX_SESSIONS do
		rebuilt[#rebuilt] = nil
	end
	self._plugin:SetSetting(INDEX_KEY, rebuilt)
end
```

Change `Sessions.load`'s return type + body to include `tasks` (defaults to `{}` for old blobs):

```lua
-- Load a saved session's title + messages + checklist (to rebuild a Conversation + TaskList), or nil
-- if missing. `tasks` defaults to {} for sessions saved before task tracking existed.
function Sessions.load(self: Sessions, id: string): { title: string, messages: { any }, tasks: { any } }?
	local raw = self._plugin:GetSetting(SESSION_PREFIX .. id)
	if type(raw) ~= "table" then
		return nil
	end
	return { title = raw.title or "", messages = raw.messages or {}, tasks = raw.tasks or {} }
end
```

- [ ] **Step 3: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 4: Commit**

```bash
git add src/init.server.luau src/Sessions.luau
git commit -m "feat(tasks): add taskList to deps; persist + load the checklist per session"
```

---

## Task 5: the panel checklist (render, reflow, lifecycle)

**Files:**
- Modify: `src/UI/Widget.luau`

- [ ] **Step 1: Add `taskList` to `Deps` + a completed-status color**

In the `Deps` type, add:

```lua
	taskList: any,
```

Below the existing color constants, add a completed-task color:

```lua
local DONE = Color3.fromRGB(120, 190, 130)
```

- [ ] **Step 2: Add the layout constants + build the checklist UI**

Just below the existing `local TOP = 96` / `local INPUT_H = 70` (the `scroller()` setup region), add the checklist constants:

```lua
	-- Checklist (update_tasks) layout constants. The checklist is pinned at y=TOP and the transcript
	-- reflows below it; height is derived from task count + collapsed state (no AutomaticSize race).
	local HEADER_H = 24
	local ROW_H = 20
	local MAX_BODY = 140
	local GAP = 4
```

After `local transcript = scroller()` and `local sessionList = scroller()` (sessionList hidden), build the checklist container, header button, and body, parented to `root`:

```lua
	-- Checklist container (between the control row and the transcript). Hidden when empty or while the
	-- sessions/history view is shown. Manual height; the transcript's geometry follows via layoutChecklist().
	local checklist = Instance.new("Frame")
	checklist.Name = "Checklist"
	checklist.BackgroundTransparency = 1
	checklist.Position = UDim2.fromOffset(0, TOP)
	checklist.Size = UDim2.new(1, 0, 0, 0)
	checklist.Visible = false
	checklist.Parent = root

	local checklistHeader = button("Tasks")
	checklistHeader.BackgroundColor3 = Color3.fromRGB(44, 44, 48)
	checklistHeader.Size = UDim2.new(1, 0, 0, HEADER_H)
	checklistHeader.Position = UDim2.fromOffset(0, 0)
	checklistHeader.TextXAlignment = Enum.TextXAlignment.Left
	checklistHeader.TextSize = 13
	checklistHeader.Parent = checklist
	local headerPad = Instance.new("UIPadding")
	headerPad.PaddingLeft = UDim.new(0, 6)
	headerPad.Parent = checklistHeader

	local checklistBody = Instance.new("ScrollingFrame")
	checklistBody.Name = "ChecklistBody"
	checklistBody.BackgroundTransparency = 1
	checklistBody.BorderSizePixel = 0
	checklistBody.Position = UDim2.fromOffset(0, HEADER_H)
	checklistBody.Size = UDim2.new(1, 0, 0, 0)
	checklistBody.ScrollBarThickness = 4
	checklistBody.CanvasSize = UDim2.new()
	checklistBody.AutomaticCanvasSize = Enum.AutomaticSize.Y
	checklistBody.Parent = checklist
	local bodyList = Instance.new("UIListLayout")
	bodyList.Padding = UDim.new(0, 0)
	bodyList.SortOrder = Enum.SortOrder.LayoutOrder
	bodyList.Parent = checklistBody
	local bodyPad = Instance.new("UIPadding")
	bodyPad.PaddingLeft = UDim.new(0, 6)
	bodyPad.Parent = checklistBody
```

- [ ] **Step 3: Add the render + reflow functions**

After the checklist UI is built (and after `transcript`/`sessionList` exist), add the state + functions. Place this above the "Transcript rendering" section so `layoutChecklist` is in scope for `showSessions` later:

```lua
	-- Checklist state + rendering ----------------------------------------------------------------
	local currentTasks: { any } = {}
	local checklistCollapsed = false

	local function rebuildChecklistRows()
		for _, child in checklistBody:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		for i, t in ipairs(currentTasks) do
			local glyph, color
			if t.status == "completed" then
				glyph, color = "●", DONE
			elseif t.status == "in_progress" then
				glyph, color = "◐", YOU
			else
				glyph, color = "○", MUTED
			end
			local row = Instance.new("TextLabel")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, -8, 0, ROW_H)
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.TextYAlignment = Enum.TextYAlignment.Center
			row.TextTruncate = Enum.TextTruncate.AtEnd
			row.TextColor3 = color
			row.TextSize = 13
			row.Font = Enum.Font.Gotham
			row.Text = glyph .. "  " .. tostring(t.content)
			row.LayoutOrder = i
			row.Parent = checklistBody
		end
	end

	-- Size the checklist from task count + collapsed state and reflow the transcript below it. Hidden
	-- when empty or while the sessions view is shown. Called on every event that can change height.
	local function layoutChecklist()
		local n = #currentTasks
		local show = n > 0 and not sessionList.Visible
		checklist.Visible = show

		local done = 0
		for _, t in ipairs(currentTasks) do
			if t.status == "completed" then
				done += 1
			end
		end
		local chevron = if checklistCollapsed then "▸ " else "▾ "
		checklistHeader.Text = chevron .. "Tasks  " .. tostring(done) .. "/" .. tostring(n)

		local bodyH = if checklistCollapsed then 0 else math.min(n * ROW_H, MAX_BODY)
		checklistBody.Visible = show and not checklistCollapsed
		checklistBody.Size = UDim2.new(1, 0, 0, bodyH)

		local h = if show then HEADER_H + bodyH else 0
		checklist.Size = UDim2.new(1, 0, 0, h)

		local top = TOP + (if h > 0 then h + GAP else 0)
		transcript.Position = UDim2.fromOffset(0, top)
		transcript.Size = UDim2.new(1, 0, 1, -(top + INPUT_H + 4))
	end

	local function renderChecklist(tasks: { any })
		currentTasks = tasks or {}
		rebuildChecklistRows()
		layoutChecklist()
	end

	checklistHeader.Activated:Connect(function()
		checklistCollapsed = not checklistCollapsed
		layoutChecklist()
	end)
```

- [ ] **Step 4: Make `showSessions` reflow the checklist**

Change `showSessions` (currently sets `sessionList.Visible` / `transcript.Visible` / `histBtn.Text`) to call `layoutChecklist()` at the end so the checklist hides in History view and returns afterward:

```lua
	local function showSessions(show: boolean)
		sessionList.Visible = show
		transcript.Visible = not show
		histBtn.Text = if show then "Back" else "History"
		layoutChecklist()
	end
```

- [ ] **Step 5: Wire the lifecycle (new chat, open session, mount, send, save)**

In `openSession`, after `deps.conversation:load(data.title, data.messages)` and before `rebuildTranscript()`, load + render the checklist:

```lua
		deps.taskList:load(data.tasks)
		renderChecklist(deps.taskList:snapshot())
```

In `newBtn.Activated`, after `deps.conversation:clear()`, clear + re-render the checklist:

```lua
		deps.taskList:clear()
		renderChecklist({})
```

In `sendBtn.Activated`, change the `deps.agentLoop.send(...)` call to pass `deps.taskList` after `deps.conversation`:

```lua
		deps.agentLoop.send(
			deps.anthropic,
			deps.config,
			deps.systemPrompt,
			deps.conversation,
			deps.taskList,
			text,
			{
```

In the `onEvent` handler, add a `tasks` branch (e.g. right after the `notice` branch):

```lua
					elseif event == "tasks" then
						renderChecklist(data)
```

In the same handler's `done` branch, change the save call to pass the checklist snapshot:

```lua
							deps.sessions:save(deps.conversation, currentId, deps.taskList:snapshot())
```

At the very end of `Widget.mount` (after the final `rebuildTranscript()`), restore the checklist after a re-mount:

```lua
	renderChecklist(deps.taskList:snapshot())
```

- [ ] **Step 6: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean. (If `selene` flags `glyph, color` as needing types, it won't — they're inferred; if it flags an unused local, remove it.)

- [ ] **Step 7: Commit**

```bash
git add src/UI/Widget.luau
git commit -m "feat(tasks): render the checklist panel section with reflow + lifecycle wiring"
```

---

## Task 6: system prompt guidance

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Add the tool line to the tools list**

In `BASE`, in the "# Tools — choose the right one" list, after the `web_fetch / web_search` bullet, add:

```
- update_tasks(tasks): maintain a VISIBLE multi-step checklist in the panel so the user sees your plan + progress — see "Track multi-step work".
```

- [ ] **Step 2: Add the "Track multi-step work" section**

In `BASE`, insert this section right before `# Working rules`:

```
# Track multi-step work
For any build that takes several steps (~3+), call update_tasks to show the user a live checklist of your plan and progress. Send the FULL list every time — it replaces the whole checklist: each task is { content, status } with status "pending", "in_progress", or "completed". Keep exactly ONE task "in_progress" at a time, and flip a task to "completed" the moment that step is actually done (after you've verified it) — don't batch completions at the end. Keep content short and outcome-shaped ("Build the inventory grid", not "call create_instance to add a Frame"). Skip the checklist for a trivial single-step request. It is a visibility aid: it does not build or change anything — you still do the work with the build tools and verify as usual. Sending an empty list clears it.
```

(The SUBAGENT prompt is unchanged — children have no `update_tasks`.)

- [ ] **Step 3: Statically verify**

Run: `selene src` and `stylua --check src`
Expected: 0 errors / clean.

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(tasks): document update_tasks + multi-step tracking in the system prompt"
```

---

## Task 7: build, full lint, and feature commit

**Files:** none (verification + build artifact)

- [ ] **Step 1: Full build**

Run: `.\build.ps1`
Expected: `rojo build` succeeds → `StudioAgent.rbxm` copied to the Plugins folder. No build errors.

- [ ] **Step 2: Full lint sweep**

Run: `selene src` (expect 0 errors; the single `CreateDockWidgetPluginGui` deprecation warning is pre-existing and unrelated) and `stylua --check src` (expect clean).

- [ ] **Step 3: (Optional, for the in-Studio run) temporarily enable the spec**

To let the user run `TaskListSpec` in Studio, temporarily add to `src/init.server.luau` near the end:

```lua
require(script.TaskListSpec).run()
```

Build, have the user reopen Studio, read Output for `=== Summary: N/N passed ===`, then REMOVE that line and rebuild (the spec is not shipped enabled, matching WebSpec/SubagentsSpec).

- [ ] **Step 4: Commit the build artifact (if tracked) + any doc updates**

```bash
git add -A
git commit -m "build(tasks): rebuild StudioAgent.rbxm with task tracking"
```

---

## Self-Review (run after writing; fix inline)

**Spec coverage** — each spec section maps to a task:
- Tool (declarative replace) → Task 2. State module (survives re-mount + compaction) → Task 1 + Task 4 (deps). Loop-owned emit → Task 3. Subagent isolation → not-in-allowlist (Task 2 leaves `READ_ONLY` untouched) + nil-taskList guard (Task 2 `run`) — covered. Persistence → Task 4. Validation/normalization → Task 1. UI/reflow → Task 5. System prompt → Task 6. Self-test → Task 1 (`TaskListSpec`). Build/lint → Task 7. ✓ no gaps.

**Type/name consistency** — `TaskList.new/normalize/counts/render/set/snapshot/load/clear`, `MAX_CONTENT`/`MAX_TASKS`, `taskList` (deps + context + params), `update_tasks` (tool name), event `"tasks"`, `currentTasks`/`checklistCollapsed`/`layoutChecklist`/`renderChecklist`/`rebuildChecklistRows`, `HEADER_H`/`ROW_H`/`MAX_BODY`/`GAP`/`TOP`/`INPUT_H`, Sessions `save(...,tasks)` / `load(...).tasks` — all consistent across tasks. ✓

**Placeholder scan** — every code step shows complete code; no TBD/"handle edge cases"/"similar to". ✓

**Ordering note** — Sessions.save's new `tasks` param is optional (`tasks or {}`), so Task 4 landing before Task 5 updates the Widget caller is safe (the 2-arg call just persists an empty checklist until Task 5).
