--!strict
-- AgentLoop (M6, M12): the Anthropic tool loop, now driving a persistent Conversation so chats
-- have memory. send() appends the user message to the conversation and runs until a terminal stop
-- or the iteration cap, appending the assistant/tool turns AS IT GOES. Separate from Anthropic.luau
-- (the HTTP client) so the verified M2 client is untouched.
--
-- Correctness rules (the API 400s without these):
--   * Assistant content is echoed back VERBATIM; tool_use PRESENCE (not stop_reason) decides whether
--     the turn continues; every tool_use gets exactly one tool_result in ONE following user message.
--   * The conversation must always END ON AN ASSISTANT TURN after a Send (alternating roles, no
--     dangling tool_use). So every NON-clean exit (request error / cancel / iteration cap / protocol)
--     rolls the conversation back to the pre-Send snapshot; only a clean terminal stop keeps it.
--   * Transient failures (Overloaded / rate-limit / 5xx / transport / the cold-proxy routing race)
--     auto-retry with backoff. The subscription usage-window ("out of extra usage") is NOT retried.
--   * emit() (UI callback) is pcall-guarded so a throwing handler can't corrupt loop control.

local Tools = require(script.Parent.Tools)
local Compactor = require(script.Parent.Compactor)
local MessageUtil = require(script.Parent.MessageUtil)
local Retry = require(script.Parent.Retry)

local AgentLoop = {}

export type Callbacks = {
	onEvent: ((event: string, data: any) -> ())?,
	shouldCancel: (() -> boolean)?,
}

local function runLoop(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	snapshot: number,
	cb: Callbacks
)
	local function emit(event: string, data: any)
		if cb.onEvent then
			pcall(cb.onEvent, event, data)
		end
	end
	local function cancelled(): boolean
		return cb.shouldCancel ~= nil and cb.shouldCancel()
	end
	-- True once a compaction has rebuilt the history this Send. After that the absolute pre-Send
	-- snapshot index is meaningless (the array is far shorter), so rollback must NOT count-truncate.
	local compacted = false
	-- Pre-Send checklist state, restored in lockstep with the conversation on a non-clean exit. The
	-- update_tasks tool mutates taskList IN PLACE and the panel re-renders mid-turn, but if a later
	-- iteration fails/cancels we roll the whole turn back — so the checklist must revert too, else the
	-- panel (and a cancel-path save) would diverge from the rolled-back conversation + persisted blob.
	local taskSnapshot = if taskList ~= nil then taskList:snapshot() else nil
	-- Restore a valid resting state on a non-clean exit. Normally truncate back to the pre-Send
	-- snapshot (which ends on the prior assistant turn). But after a compaction, instead ensure the
	-- history ends on an assistant turn so the next user message still alternates (a stale snapshot
	-- index would make truncate a silent no-op and leave the history ending on a user turn).
	local function rollback()
		if compacted then
			local msgs = conversation.messages
			local last = msgs[#msgs]
			if last ~= nil and last.role ~= "assistant" then
				conversation:appendAssistant({ { type = "text", text = "(turn interrupted)" } })
			end
		else
			conversation:truncate(snapshot)
		end
		if taskList ~= nil and taskSnapshot ~= nil then
			taskList:load(taskSnapshot)
			emit("tasks", taskList:snapshot())
		end
	end
	-- Roll the conversation back and surface why. Keeps history API-valid.
	local function abort(kind: string, message: any)
		rollback()
		emit("error", { kind = kind, message = message })
	end
	-- Compact, mark the flag, and notify. Returns whether it actually compacted.
	local function doCompact(): boolean
		local ok = Compactor.compact(anthropic, config, conversation)
		if ok then
			compacted = true
			emit("notice", "[compacted earlier history to free context]")
		end
		return ok
	end

	local messages = conversation.messages
	local tools = Tools.schemas()
	local maxIter = config:getMaxIterations()
	-- Dependencies a tool may need at run time (e.g. `capture` reads context.config for the sidecar;
	-- `update_tasks` mutates context.taskList — the in-panel checklist).
	local toolContext = { config = config, anthropic = anthropic, taskList = taskList }

	for i = 1, maxIter do
		if cancelled() then
			rollback()
			emit("done", { stop = "cancelled" })
			return
		end
		emit("iteration", { n = i, max = maxIter })

		-- Always-on: keep only the most recent screenshot in live context.
		Compactor.pruneImagesKeepingLast(messages)
		-- Proactive: if the last prompt crossed the threshold, compact before sending.
		if Compactor.shouldCompact(conversation.lastPromptTokens, config) then
			emit("status", "compacting context…")
			doCompact()
		end

		-- Send, with a one-shot reactive compaction if we still overflow the window. compact()
		-- mutates conversation.messages IN PLACE, so the `messages` local stays valid (no re-bind).
		local res
		local compactedReactively = false
		while true do
			res = Retry.sendWithRetry(
				anthropic,
				config,
				{ messages = messages, tools = tools, system = systemPrompt },
				emit,
				cancelled
			)
			if res.ok then
				break
			end
			if Compactor.isContextLengthError(res) and not compactedReactively then
				compactedReactively = true
				emit("status", "context full — compacting and retrying…")
				if not doCompact() then
					abort(res.kind, res.message)
					return
				end
			else
				abort(res.kind, res.message)
				return
			end
		end

		local data = res.data
		if type(data) ~= "table" or type(data.content) ~= "table" then
			abort("protocol", "response had no content array")
			return
		end
		conversation.lastPromptTokens = MessageUtil.promptTokensFromUsage(data.usage)

		local toolUses: { any } = {}
		for _, block in ipairs(data.content) do
			if type(block) == "table" then
				if block.type == "text" and type(block.text) == "string" then
					emit("assistant_text", block.text)
				elseif block.type == "tool_use" then
					table.insert(toolUses, block)
				end
			end
		end

		if #toolUses == 0 then
			-- Terminal (or a paused turn to resume). Echo the assistant turn either way.
			table.insert(messages, { role = "assistant", content = data.content })
			if data.stop_reason == "pause_turn" then
				emit("status", "pause_turn - resuming")
			else
				emit("done", { stop = data.stop_reason }) -- clean exit: ends on an assistant turn
				return
			end
		else
			if cancelled() then
				rollback()
				emit("done", { stop = "cancelled" })
				return
			end
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
		end
	end

	-- Hit the iteration cap mid-work. The last iteration ran tools, so history ends on a tool_result
	-- user turn. Instead of truncating the whole turn (which discarded all the work + context), append
	-- a final assistant turn: it keeps the history API-valid (must end on an assistant turn) AND
	-- preserves everything, so the user can just say "continue" to resume with full context. The
	-- DataModel edits were already applied and are undoable regardless. The assistant content is a
	-- blocks array (not a bare string) so it round-trips and re-renders on session reload like a real
	-- assistant turn.
	local capNote = "I hit this turn's step limit ("
		.. tostring(maxIter)
		.. ' steps) before fully finishing. Everything I changed so far is applied — say "continue" and I\'ll pick up where I left off.'
	table.insert(messages, { role = "assistant", content = { { type = "text", text = capNote } } })
	emit("assistant_text", capNote)
	emit("done", { stop = "max_iterations" })
end

local running = false

-- Append userText to the conversation and run the loop, continuing the existing history. Single-
-- flight + exception-safe: on a throw, roll back to the pre-Send snapshot and surface it.
function AgentLoop.send(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
	taskList: any,
	userText: string,
	cb: Callbacks
)
	if running then
		if cb.onEvent then
			pcall(cb.onEvent, "error", { kind = "busy", message = "agent already running" })
		end
		return
	end
	running = true
	task.spawn(function()
		local snapshot = conversation:count()
		local taskSnapshot = if taskList ~= nil then taskList:snapshot() else nil
		conversation:appendUserText(userText)
		local ok, err =
			pcall(runLoop, anthropic, config, systemPrompt, conversation, taskList, snapshot, cb)
		running = false
		if not ok then
			conversation:truncate(snapshot)
			-- A compaction inside runLoop can shrink the history below `snapshot`, making the
			-- truncate above a silent no-op; this outer failsafe has no access to runLoop's
			-- `compacted` flag, so unconditionally ensure we still end on an assistant turn (a no-op
			-- when truncate already restored the pre-Send, assistant-ending state).
			local msgs = conversation.messages
			local last = msgs[#msgs]
			if last ~= nil and last.role ~= "assistant" then
				conversation:appendAssistant({ { type = "text", text = "(turn interrupted)" } })
			end
			-- Mirror the checklist back to its pre-Send state (the turn that changed it was discarded).
			if taskList ~= nil and taskSnapshot ~= nil then
				taskList:load(taskSnapshot)
				if cb.onEvent then
					pcall(cb.onEvent, "tasks", taskList:snapshot())
				end
			end
			if cb.onEvent then
				pcall(cb.onEvent, "error", { kind = "internal", message = tostring(err) })
			end
		end
	end)
end

return AgentLoop
