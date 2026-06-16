--!strict
-- MessageUtil: pure helpers over Anthropic message arrays (no Roblox datatypes), shared by Sessions
-- (image stripping on save) and Compactor (token accounting, history-validity, pruning).
--
-- History invariants the loop relies on (the API 400s otherwise): the array starts on a `user` turn,
-- roles strictly alternate user/assistant, every assistant `tool_use` turn is followed by a `user`
-- turn whose content is a `tool_result` blocks array, and such a `tool_result` turn is always
-- preceded by its `tool_use` turn.

local MessageUtil = {}

-- True if `content` is a blocks ARRAY whose first block is a tool_result (a tool-result user turn).
function MessageUtil.isToolResultTurn(content: any): boolean
	return type(content) == "table"
		and type(content[1]) == "table"
		and content[1].type == "tool_result"
end

-- True if `content` is a blocks ARRAY containing at least one tool_use block (an assistant tool turn).
function MessageUtil.hasToolUse(content: any): boolean
	if type(content) ~= "table" then
		return false
	end
	for _, block in ipairs(content) do
		if type(block) == "table" and block.type == "tool_use" then
			return true
		end
	end
	return false
end

-- Replace EVERY image block anywhere in `value` with a text placeholder. Non-mutating: returns a new
-- structure (the original is untouched). Used by Sessions (save) and Compactor (summary input).
function MessageUtil.stripImages(value: any, placeholder: string?): any
	local note = placeholder or "[screenshot omitted from saved history]"
	if type(value) ~= "table" then
		return value
	end
	if value.type == "image" then
		return { type = "text", text = note }
	end
	local out: { [any]: any } = {}
	for k, v in pairs(value) do
		out[k] = MessageUtil.stripImages(v, note)
	end
	return out
end

-- Sum the components of a Messages `usage` object that count against the context WINDOW (cached
-- components still occupy the window even though they cost less). Missing/absent -> 0.
function MessageUtil.promptTokensFromUsage(usage: any): number
	if type(usage) ~= "table" then
		return 0
	end
	local function n(x: any): number
		return if type(x) == "number" then x else 0
	end
	return n(usage.input_tokens)
		+ n(usage.cache_read_input_tokens)
		+ n(usage.cache_creation_input_tokens)
end

-- Check a history is Anthropic-API-valid. Returns (true) or (false, reason). An empty array is
-- treated as valid (no constraints to violate).
function MessageUtil.isValidHistory(messages: { any }): (boolean, string?)
	local n = #messages
	if n == 0 then
		return true
	end
	if type(messages[1]) ~= "table" or messages[1].role ~= "user" then
		return false, "history must start with a user turn"
	end
	for i = 1, n do
		local expected = if i % 2 == 1 then "user" else "assistant"
		if type(messages[i]) ~= "table" or messages[i].role ~= expected then
			return false,
				"roles must strictly alternate user/assistant starting with user (index "
					.. i
					.. ")"
		end
	end
	for i = 1, n do
		local msg = messages[i]
		if msg.role == "user" and MessageUtil.isToolResultTurn(msg.content) then
			local prev = messages[i - 1]
			if
				prev == nil
				or prev.role ~= "assistant"
				or not MessageUtil.hasToolUse(prev.content)
			then
				return false,
					"tool_result turn not preceded by an assistant tool_use turn (index "
						.. i
						.. ")"
			end
		end
		if msg.role == "assistant" and MessageUtil.hasToolUse(msg.content) then
			local nxt = messages[i + 1]
			if
				nxt == nil
				or nxt.role ~= "user"
				or not MessageUtil.isToolResultTurn(nxt.content)
			then
				return false,
					"assistant tool_use turn not followed by a tool_result user turn (index "
						.. i
						.. ")"
			end
		end
	end
	return true
end

return MessageUtil
