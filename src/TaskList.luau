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
	if type(rawContent) ~= "string" then
		return nil -- missing / number / table content is not a valid task (don't coerce "nil"/"5"/...)
	end
	local content = trim(rawContent)
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
		local task = normalizeOne(item)
		if task ~= nil then
			-- Invalid items are dropped silently; `dropped` counts only VALID tasks lost to the cap, so
			-- the "N dropped (cap M)" summary means exactly that (not "junk items seen after the cap").
			if #out >= MAX_TASKS then
				dropped += 1
			else
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
