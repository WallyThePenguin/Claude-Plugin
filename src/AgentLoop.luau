--!strict
-- AgentLoop (M6): the Anthropic tool loop. Kept separate from Anthropic.luau (the HTTP client)
-- so the verified M2 client is untouched. Drives: build messages -> sendMessage -> parse content
-- -> dispatch tool_use -> reply with tool_results -> repeat, until a non-tool_use stop reason or
-- the iteration cap.
--
-- Invariants (the loop 400s without these), hardened after the M6 adversarial review:
--   * The assistant `content` is echoed back VERBATIM (tool_use blocks must round-trip).
--   * Tool-call presence is AUTHORITATIVE over stop_reason: if the content has tool_use blocks we
--     answer them (one tool_result each, errors included) in ONE following user message, regardless
--     of what stop_reason says.
--   * We NEVER append an empty tool_result list (JSONEncode would emit `{}` not `[]` -> next-call
--     400). The assistant turn and its tool_result user turn are appended back-to-back with no
--     fallible call between them.
--   * A failed request returns BEFORE appending anything, so history never holds a dangling tool_use.
--   * pause_turn is NOT terminal: echo + re-request. Every other non-tool_use stop is terminal.
--   * emit() (UI callback) is pcall-guarded so a throwing callback can never be misreported as a
--     loop failure or escape the task.spawn closure.

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
	-- UI callbacks touch Studio instances and can throw; pcall so they never affect loop control.
	local function emit(event: string, data: any)
		if cb.onEvent then
			pcall(cb.onEvent, event, data)
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

		-- Surface assistant text and collect tool_use blocks. Their PRESENCE decides whether the
		-- turn continues — not stop_reason (a translating proxy can under-/mis-report it).
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
			-- No tool calls. Echo the assistant turn, then either resume (pause_turn) or finish.
			table.insert(messages, { role = "assistant", content = data.content })
			if data.stop_reason == "pause_turn" then
				emit("status", "pause_turn - resuming")
				-- loop again; nothing to answer
			else
				emit("done", { stop = data.stop_reason })
				return
			end
		else
			-- Honor a cancel BEFORE running any (possibly destructive) tool, and before echoing the
			-- assistant turn, so history is never left with an unanswered tool_use.
			if cancelled() then
				emit("done", { stop = "cancelled" })
				return
			end

			-- Build every tool_result first (emit is non-throwing; dispatch is total), then append
			-- the assistant turn and its tool_result user turn back-to-back.
			local toolResults: { any } = {}
			for _, block in ipairs(toolUses) do
				emit("tool_use", { name = block.name })
				local text, isError = Tools.dispatch(block.name, block.input)
				if text == "" then
					text = "(no output)" -- Anthropic rejects empty tool_result content
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

	emit("done", { stop = "max_iterations" })
end

local running = false

-- Start the loop under task.spawn (so the UI never yields) with an exception-safe single-flight
-- guard: `running` is always cleared, even if runLoop throws. The error callback is pcall-guarded
-- so a throwing UI handler cannot escape the spawn closure.
function AgentLoop.start(
	anthropic: any,
	config: any,
	systemPrompt: string?,
	prompt: string,
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
		local ok, err = pcall(runLoop, anthropic, config, systemPrompt, prompt, cb)
		running = false
		if not ok and cb.onEvent then
			pcall(cb.onEvent, "error", { kind = "internal", message = tostring(err) })
		end
	end)
end

return AgentLoop
