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
--     dangling tool_use). NON-clean exits (request error / cancel / internal throw) PRESERVE the
--     turn and close it with a "(turn interrupted…)" assistant note — the DataModel edits already
--     happened, so truncating the record only gave the agent amnesia about work the world kept.
--     The ONE remaining rollback is the pre-send protocol guard (there the history itself is broken).
--   * Transient failures (Overloaded / rate-limit / 5xx / transport / the cold-proxy routing race)
--     auto-retry with backoff. The subscription usage-window ("out of extra usage") is NOT retried.
--   * emit() (UI callback) is pcall-guarded so a throwing handler can't corrupt loop control.

local Tools = require(script.Parent.Tools)
local Compactor = require(script.Parent.Compactor)
local MessageUtil = require(script.Parent.MessageUtil)
local Retry = require(script.Parent.Retry)
local Relay = require(script.Parent.Relay)

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
	memory: any,
	skills: any,
	rubrics: any,
	buildGuides: any,
	cameraRig: any,
	learnings: any,
	snapshot: number,
	cb: Callbacks,
	relay: any
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
	-- snapshot index is meaningless (the array is far shorter), so the protocol-guard recovery must
	-- NOT count-truncate.
	local compacted = false
	-- PRESERVE the turn on a non-clean exit (error / cancel / internal throw): the DataModel edits
	-- already happened, so truncating the conversational record gave the agent amnesia about work
	-- the world kept — one hiccup at step 25 of a 40-step build erased the record of all 25 steps.
	-- Instead, close the history on an assistant "(turn interrupted…)" note: API-valid, and
	-- "continue" resumes with full context — exactly the iteration-cap path's proven pattern. The
	-- TaskList likewise stays as-is (it describes work that really happened).
	-- The loop never leaves a DANGLING tool_use here: assistant tool_use turns and their tool_result
	-- user turn are appended together after dispatch, so a non-clean exit ends on a USER turn (or,
	-- for pause_turn, a plain assistant turn) — appending a text note keeps the history API-valid.
	local function preserveTurn(why: string)
		local msgs = conversation.messages
		local last = msgs[#msgs]
		if last ~= nil and last.role ~= "assistant" then
			conversation:appendAssistant({
				{
					type = "text",
					text = "(turn interrupted: "
						.. why
						.. ' — everything done so far is already applied; say "continue" to resume)',
				},
			})
		end
	end
	-- The ONE remaining rollback: the pre-send protocol guard, where the HISTORY ITSELF is invalid
	-- and appending a note can't fix it. Truncate to the pre-Send snapshot (or, after a compaction
	-- made that index meaningless, just ensure an assistant tail).
	local function rollbackProtocol()
		if compacted then
			preserveTurn("history rebuilt mid-turn")
		else
			conversation:truncate(snapshot)
		end
	end
	-- Preserve the turn and surface why. Keeps history API-valid.
	local function abort(kind: string, message: any)
		local short = tostring(message)
		if #short > 200 then
			short = string.sub(short, 1, 200) .. "…"
		end
		preserveTurn(
			tostring(kind) .. (if short ~= "" and short ~= "nil" then " — " .. short else "")
		)
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
	local tools = Tools.schemas(config)
	local maxIter = config:getMaxIterations()
	-- Dependencies a tool may need at run time (e.g. `capture` reads context.config for the sidecar;
	-- `update_tasks` mutates context.taskList; `remember`/`forget` mutate context.memory).
	local toolContext = {
		config = config,
		anthropic = anthropic,
		taskList = taskList,
		memory = memory,
		skills = skills,
		rubrics = rubrics,
		buildGuides = buildGuides,
		cameraRig = cameraRig,
		learnings = learnings,
	}

	-- System-prompt + memory delivery (verified live): the model proxy (CLIProxyAPI subscription path)
	-- STRIPS the client `system` field and injects its own Claude Code prompt, so neither the plugin's
	-- SystemPrompt nor the recalled memory reach the model via `system`. MESSAGE content DOES pass
	-- through, so both are delivered as a LEADING user/assistant pair prepended to the sent messages
	-- (MessageUtil.withSystemPreamble), and `system` is OMITTED. The preamble is rebuilt per send and is
	-- NOT stored in conversation.messages, so history, persistence, rollback, and compaction are all
	-- unaffected. `instructions` (base prompt + recalled memory) is composed once per Send here.
	local instructions = systemPrompt or ""
	if memory ~= nil then
		local block = memory:promptBlock()
		if block ~= "" then
			instructions = if instructions == "" then block else instructions .. "\n\n" .. block
		end
	end
	if skills ~= nil then
		local cat = skills:catalogBlock()
		if cat ~= "" then
			instructions = if instructions == "" then cat else instructions .. "\n\n" .. cat
		end
	end
	if rubrics ~= nil then
		local cat = rubrics:catalogBlock()
		if cat ~= "" then
			instructions = if instructions == "" then cat else instructions .. "\n\n" .. cat
		end
	end
	if buildGuides ~= nil then
		local cat = buildGuides:catalogBlock()
		if cat ~= "" then
			instructions = if instructions == "" then cat else instructions .. "\n\n" .. cat
		end
	end
	if learnings ~= nil then
		local block = learnings:promptBlock()
		if block ~= "" then
			instructions = if instructions == "" then block else instructions .. "\n\n" .. block
		end
	end

	for i = 1, maxIter do
		if cancelled() then
			preserveTurn("cancelled by user")
			emit("done", { stop = "cancelled" })
			return
		end
		emit("iteration", { n = i, max = maxIter })

		-- Always-on: keep only the most recent K screenshots in live context (K >= 2 lets the
		-- model compare before/after captures while iterating visually).
		Compactor.pruneImagesKeepingLast(messages, config:getImagesKept())
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
			-- Deliver instructions+memory via the leading preamble (the proxy strips `system`).
			local sent = MessageUtil.withSystemPreamble(instructions, messages)
			-- Defence-in-depth: never POST an API-invalid history (e.g. a stray pause_turn double-
			-- assistant turn). This is the one case where the history ITSELF is broken, so recover
			-- by rollback (not by appending a note to a broken tail).
			if not MessageUtil.isValidHistory(sent) then
				rollbackProtocol()
				emit("error", {
					kind = "protocol",
					message = "history would be API-invalid before send",
				})
				return
			end
			res = Retry.sendWithRetry(
				anthropic,
				config,
				{ messages = sent, tools = tools },
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
				elseif block.type == "server_tool_use" then
					-- Anthropic runs this server-side (web_search/web_fetch). It is NOT a local
					-- tool_use, so it is never dispatched, and the matching *_tool_result block
					-- already rides in this same assistant turn. Surface progress only.
					local inp = if type(block.input) == "table" then block.input else {}
					local detail = tostring(inp.query or inp.url or "")
					emit(
						"status",
						tostring(block.name) .. (if detail ~= "" then " " .. detail else "")
					)
				end
			end
		end

		if #toolUses == 0 then
			-- Empty content array (0 output blocks — e.g. the cap was hit before any block emitted):
			-- the API forbids an empty-content assistant turn, and isValidHistory doesn't catch it,
			-- so echoing + resending it would 400 the next Send. It can't be usefully continued —
			-- treat it as terminal (do NOT append the empty turn). Covers max_tokens AND pause_turn.
			if #data.content == 0 then
				emit("done", { stop = data.stop_reason })
				return
			end
			-- Terminal (or a paused/output-capped turn to resume). Echo the assistant turn either way.
			table.insert(messages, { role = "assistant", content = data.content })
			if data.stop_reason == "pause_turn" then
				emit("status", "pause_turn - resuming")
			elseif data.stop_reason == "max_tokens" then
				-- The output hit the token cap mid-generation (routine when writing a long script
				-- Source). Nudge and CONTINUE the loop (bounded by the iteration cap) instead of
				-- ending the turn with silently-truncated text.
				table.insert(messages, {
					role = "user",
					content = "(your last message hit the output-token cap mid-stream — continue exactly where it cut off)",
				})
				emit("status", "output token cap — continuing")
			else
				emit("done", { stop = data.stop_reason }) -- clean exit: ends on an assistant turn
				return
			end
		else
			if cancelled() then
				preserveTurn("cancelled by user")
				emit("done", { stop = "cancelled" })
				return
			end
			local toolResults: { any } = {}
			local tasksChanged = false
			for _, block in ipairs(toolUses) do
				emit("tool_use", { name = block.name })
				-- In client-view play, relay DataModel/HTTP/dispatch tools to the server copy; run
				-- plugin-only tools (update_tasks/remember/forget/skills) locally. No relay -> all
				-- local (edit / Server-view play), exactly as today.
				local content, isError
				if relay ~= nil and Relay.shouldRelayTool(block.name) then
					content, isError = relay.tool(block.name, block.input)
				else
					content, isError = Tools.dispatch(block.name, block.input, toolContext)
				end
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
	memory: any,
	skills: any,
	rubrics: any,
	buildGuides: any,
	cameraRig: any,
	learnings: any,
	userText: string,
	cb: Callbacks,
	relay: any
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
		local ok, err = pcall(
			runLoop,
			anthropic,
			config,
			systemPrompt,
			conversation,
			taskList,
			memory,
			skills,
			rubrics,
			buildGuides,
			cameraRig,
			learnings,
			snapshot,
			cb,
			relay
		)
		running = false
		if not ok then
			-- runLoop threw. PRESERVE whatever the turn accomplished (the DataModel edits already
			-- happened — same rationale as preserveTurn inside the loop); just guarantee the
			-- history still ends on an assistant turn so the next Send alternates.
			local msgs = conversation.messages
			local last = msgs[#msgs]
			if last ~= nil and last.role ~= "assistant" then
				conversation:appendAssistant({
					{
						type = "text",
						text = '(turn interrupted: internal error — everything done so far is already applied; say "continue" to resume)',
					},
				})
			end
			if cb.onEvent then
				pcall(cb.onEvent, "error", { kind = "internal", message = tostring(err) })
			end
		end
	end)
end

return AgentLoop
