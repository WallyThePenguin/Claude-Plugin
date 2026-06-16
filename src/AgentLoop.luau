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

	for i = 1, maxIter do
		if cancelled() then
			conversation:truncate(snapshot)
			emit("done", { stop = "cancelled" })
			return
		end
		emit("iteration", { n = i, max = maxIter })

		local res = sendWithRetry(
			anthropic,
			config,
			{ messages = messages, tools = tools, system = systemPrompt },
			emit,
			cancelled
		)
		if not res.ok then
			abort(res.kind, res.message)
			return
		end

		local data = res.data
		if type(data) ~= "table" or type(data.content) ~= "table" then
			abort("protocol", "response had no content array")
			return
		end

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
				local text, isError = Tools.dispatch(block.name, block.input)
				if text == "" then
					text = "(no output)"
				end
				emit("tool_result", { name = block.name, isError = isError, text = text })
				table.insert(toolResults, {
					type = "tool_result",
					tool_use_id = block.id,
					content = text,
					is_error = isError,
				})
			end
			table.insert(messages, { role = "assistant", content = data.content })
			table.insert(messages, { role = "user", content = toolResults })
		end
	end

	-- Hit the iteration cap mid-work: the history may end on a tool_result user turn, so roll back to
	-- keep it valid and tell the user (the DataModel edits themselves persist + are undoable).
	conversation:truncate(snapshot)
	emit("error", { kind = "max_iterations", message = "hit the iteration cap before finishing" })
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
