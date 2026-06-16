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

local AgentLoop = {}

export type Callbacks = {
	onEvent: ((event: string, data: any) -> ())?,
	shouldCancel: (() -> boolean)?,
}

-- Worth retrying? Transient server/transport conditions, NOT the usage-window or a real client error.
local function isTransient(res: any): boolean
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
			return false -- usage window: retrying re-reserves max_tokens and worsens it
		end
		if string.find(msg, "overloaded", 1, true) then
			return true
		end
		if string.find(msg, "unknown provider for model", 1, true) then
			return true -- cold-proxy routing race; clears once the proxy warms up
		end
	end
	return false
end

-- sendMessage with capped exponential backoff on transient failures.
local function sendWithRetry(
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
		if attempt >= maxAttempts or cancelled() or not isTransient(res) then
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

local function runLoop(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	conversation: any,
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
	-- Roll the conversation back to the pre-Send state and surface why. Keeps history API-valid.
	local function abort(kind: string, message: any)
		conversation:truncate(snapshot)
		emit("error", { kind = kind, message = message })
	end

	local messages = conversation.messages
	local tools = Tools.schemas()
	local maxIter = config:getMaxIterations()
	-- Dependencies a tool may need at run time (e.g. `capture` reads context.config for the sidecar).
	local toolContext = { config = config, anthropic = anthropic }

	for i = 1, maxIter do
		if cancelled() then
			conversation:truncate(snapshot)
			emit("done", { stop = "cancelled" })
			return
		end
		emit("iteration", { n = i, max = maxIter })

		-- Always-on: keep only the most recent screenshot in live context.
		Compactor.pruneImagesKeepingLast(messages)
		-- Proactive: if the last prompt crossed the threshold, compact before sending.
		if Compactor.shouldCompact(conversation.lastPromptTokens, config) then
			emit("status", "compacting context…")
			local didCompact = Compactor.compact(anthropic, config, conversation)
			if didCompact then
				emit("notice", "[compacted earlier history to free context]")
			end
		end

		-- Send, with a one-shot reactive compaction if we still overflow the window. compact()
		-- mutates conversation.messages IN PLACE, so the `messages` local stays valid (no re-bind).
		local res
		local compactedReactively = false
		while true do
			res = sendWithRetry(
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
				if Compactor.compact(anthropic, config, conversation) then
					emit("notice", "[compacted earlier history to free context]")
				else
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
				conversation:truncate(snapshot)
				emit("done", { stop = "cancelled" })
				return
			end
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
		conversation:appendUserText(userText)
		local ok, err = pcall(runLoop, anthropic, config, systemPrompt, conversation, snapshot, cb)
		running = false
		if not ok then
			conversation:truncate(snapshot)
			if cb.onEvent then
				pcall(cb.onEvent, "error", { kind = "internal", message = tostring(err) })
			end
		end
	end)
end

return AgentLoop
