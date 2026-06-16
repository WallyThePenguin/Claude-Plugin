--!strict
-- AgentLoop (M6): the Anthropic tool loop. Kept separate from Anthropic.luau (the HTTP client)
-- so the verified M2 client is untouched. Drives: build messages -> sendMessage -> parse content
-- -> dispatch tool_use -> reply with tool_results -> repeat, until a non-tool_use stop reason or
-- the iteration cap.
--
-- Invariants (the loop 400s without these):
--   * The assistant `content` is echoed back VERBATIM (tool_use blocks must round-trip).
--   * For a tool_use turn, EVERY tool_use block gets exactly one tool_result (errors included),
--     all in ONE following user message.
--   * A terminal failure does NOT leave a trailing unanswered tool_use turn (we return before
--     appending the assistant turn when the request itself failed).

local Tools = require(script.Parent.Tools)

local AgentLoop = {}

export type Callbacks = {
	onEvent: ((event: string, data: any) -> ())?,
	shouldCancel: (() -> boolean)?,
}

local function runLoop(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	prompt: string,
	cb: Callbacks
)
	local function emit(event: string, data: any)
		if cb.onEvent then
			cb.onEvent(event, data)
		end
	end
	local function cancelled(): boolean
		return cb.shouldCancel ~= nil and cb.shouldCancel()
	end

	local messages: { any } = { { role = "user", content = prompt } }
	local tools = Tools.schemas()
	local maxIter = config:getMaxIterations()

	for i = 1, maxIter do
		if cancelled() then
			emit("done", { stop = "cancelled" })
			return
		end
		emit("iteration", { n = i, max = maxIter })

		local res =
			anthropic:sendMessage({ messages = messages, tools = tools, system = systemPrompt })
		if not res.ok then
			-- Request failed: surface and stop. No assistant turn was appended this iteration, so
			-- history has no dangling tool_use to poison a later request.
			emit("error", { kind = res.kind, message = res.message })
			return
		end

		local data = res.data
		if type(data) ~= "table" or type(data.content) ~= "table" then
			emit("error", { kind = "protocol", message = "response had no content array" })
			return
		end

		-- Echo the assistant turn back verbatim (tool_use ids must round-trip unchanged).
		table.insert(messages, { role = "assistant", content = data.content })

		for _, block in ipairs(data.content) do
			if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
				emit("assistant_text", block.text)
			end
		end

		if data.stop_reason ~= "tool_use" then
			emit("done", { stop = data.stop_reason })
			return
		end

		-- Dispatch every tool_use block; collect a tool_result for each (errors included).
		local toolResults: { any } = {}
		for _, block in ipairs(data.content) do
			if type(block) == "table" and block.type == "tool_use" then
				emit("tool_use", { name = block.name })
				local text, isError = Tools.dispatch(block.name, block.input)
				emit("tool_result", { name = block.name, isError = isError, text = text })
				table.insert(toolResults, {
					type = "tool_result",
					tool_use_id = block.id,
					content = text,
					is_error = isError,
				})
			end
		end
		-- One user message carrying all tool_results, ordered first.
		table.insert(messages, { role = "user", content = toolResults })
	end

	emit("done", { stop = "max_iterations" })
end

local running = false

-- Start the loop under task.spawn (so the UI never yields) with an exception-safe single-flight
-- guard: `running` is always cleared, even if runLoop throws.
function AgentLoop.start(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	prompt: string,
	cb: Callbacks
)
	if running then
		if cb.onEvent then
			cb.onEvent("error", { kind = "busy", message = "agent already running" })
		end
		return
	end
	running = true
	task.spawn(function()
		local ok, err = pcall(runLoop, anthropic, config, systemPrompt, prompt, cb)
		running = false
		if not ok and cb.onEvent then
			cb.onEvent("error", { kind = "internal", message = tostring(err) })
		end
	end)
end

return AgentLoop
