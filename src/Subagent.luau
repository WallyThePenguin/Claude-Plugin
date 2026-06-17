--!strict
-- Subagent: a minimal, ephemeral, READ-ONLY child agent loop used by the dispatch_subagents tool.
-- Unlike AgentLoop.runLoop it has NO rollback / compaction / persistence / single-flight — children
-- are throwaway and never persisted. It shares the transient-retry path (Retry) with the parent loop.
-- run() returns the child's final assistant text (its entire contribution back to the parent).

local Tools = require(script.Parent.Tools)
local Retry = require(script.Parent.Retry)
local MessageUtil = require(script.Parent.MessageUtil)

local Subagent = {}

export type Opts = {
	anthropic: any,
	config: any,
	systemPrompt: string,
	taskPrompt: string,
	toolSchemas: { any },
	allowedTools: { [string]: boolean },
	model: string,
	maxIterations: number,
	shouldCancel: (() -> boolean)?,
	writeRegion: Instance?,
}

export type Result = { text: string, ok: boolean, capped: boolean }

local function noop(_event: string, _data: any) end

-- Concatenate the text blocks of an assistant response's content array.
local function collectText(content: any): string
	if type(content) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	for _, block in ipairs(content) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			table.insert(parts, block.text)
		end
	end
	return table.concat(parts, "")
end

function Subagent.run(opts: Opts): Result
	local cancelled = function(): boolean
		return opts.shouldCancel ~= nil and opts.shouldCancel()
	end
	local context = {
		config = opts.config,
		anthropic = opts.anthropic,
		allowedTools = opts.allowedTools,
		writeRegion = opts.writeRegion, -- nil for read-only subagents; a region Instance for writers
	}
	-- The model proxy strips the `system` field (see AgentLoop / HANDOFF), so the child's instructions
	-- (SUBAGENT_BASE + role + the OUTPUT CONTRACT) are delivered as a LEADING preamble seeded into the
	-- message history, NOT via `system`. Children are ephemeral (no compaction/persistence), so seeding
	-- the preamble once into `messages` is fine; the loop appends after it.
	local messages: { any } = MessageUtil.withSystemPreamble(
		opts.systemPrompt,
		{ { role = "user", content = opts.taskPrompt } }
	)
	local lastText = ""

	for _ = 1, opts.maxIterations do
		if cancelled() then
			return { text = lastText, ok = true, capped = false }
		end
		local res = Retry.sendWithRetry(opts.anthropic, opts.config, {
			messages = messages,
			tools = opts.toolSchemas,
			model = opts.model,
		}, noop, cancelled)
		if not res.ok then
			return {
				text = "subagent request error: " .. tostring(res.message),
				ok = false,
				capped = false,
			}
		end
		local data = res.data
		if type(data) ~= "table" or type(data.content) ~= "table" then
			return { text = "subagent: malformed response", ok = false, capped = false }
		end

		local toolUses: { any } = {}
		for _, block in ipairs(data.content) do
			if type(block) == "table" and block.type == "tool_use" then
				table.insert(toolUses, block)
			end
		end

		if #toolUses == 0 then
			-- Terminal turn: the child's final text is its return value.
			return { text = collectText(data.content), ok = true, capped = false }
		end

		local toolResults: { any } = {}
		for _, block in ipairs(toolUses) do
			local content, isError = Tools.dispatch(block.name, block.input, context)
			if type(content) == "string" and content == "" then
				content = "(no output)"
			end
			table.insert(toolResults, {
				type = "tool_result",
				tool_use_id = block.id,
				content = content,
				is_error = isError,
			})
		end
		table.insert(messages, { role = "assistant", content = data.content })
		table.insert(messages, { role = "user", content = toolResults })
		lastText = collectText(data.content)
	end

	return {
		text = if lastText ~= ""
			then lastText
			else "(subagent hit its step limit before reporting)",
		ok = true,
		capped = true,
	}
end

return Subagent
