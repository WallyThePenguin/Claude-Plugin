--!strict
-- Conversation (M12): the running multi-turn message history for ONE chat session. This is the
-- source of truth the agent loop continues across each Send, so follow-ups carry full context
-- ("add the click handler" remembers the GUI it just built). Saving/listing/reloading sessions
-- across restarts is layered on top in Sessions.luau (next step).
--
-- Invariant the loop relies on: after a completed Send the messages END on an assistant turn, so
-- the next user message alternates correctly (the Anthropic API requires alternating roles and no
-- trailing unanswered tool_use). The loop enforces this by rolling back to a pre-Send snapshot on
-- any non-clean exit (error / cancel / iteration cap).

local Conversation = {}
Conversation.__index = Conversation

export type Conversation = typeof(setmetatable(
	{} :: {
		messages: { any },
		title: string,
		lastPromptTokens: number,
	},
	Conversation
))

function Conversation.new(): Conversation
	return setmetatable({ messages = {}, title = "", lastPromptTokens = 0 }, Conversation)
end

-- A short title derived from the first user message (for the session list).
local function deriveTitle(text: string): string
	local t = (string.gsub(text, "%s+", " "))
	t = (string.gsub(t, "^ ", ""))
	if #t > 48 then
		return string.sub(t, 1, 48) .. "..."
	end
	return t
end

function Conversation.appendUserText(self: Conversation, text: string)
	if self.title == "" then
		self.title = deriveTitle(text)
	end
	table.insert(self.messages, { role = "user", content = text })
end

-- Echo the assistant turn back VERBATIM (tool_use blocks must round-trip unchanged).
function Conversation.appendAssistant(self: Conversation, content: any)
	table.insert(self.messages, { role = "assistant", content = content })
end

-- One user message carrying all tool_result blocks for the preceding assistant tool_use turn.
function Conversation.appendToolResults(self: Conversation, blocks: { any })
	table.insert(self.messages, { role = "user", content = blocks })
end

function Conversation.count(self: Conversation): number
	return #self.messages
end

-- Roll back to a previous message count. Used to keep the conversation API-valid (alternating
-- roles, no dangling tool_use) when a Send fails / is cancelled / hits the iteration cap partway.
function Conversation.truncate(self: Conversation, n: number)
	for i = #self.messages, n + 1, -1 do
		self.messages[i] = nil
	end
end

-- Replace the message list IN PLACE (clear + refill the same table) so existing references to
-- `conversation.messages` (e.g. the running loop's local) stay valid after a compaction.
function Conversation.replaceMessages(self: Conversation, new: { any })
	table.clear(self.messages)
	for _, m in ipairs(new) do
		table.insert(self.messages, m)
	end
end

function Conversation.clear(self: Conversation)
	table.clear(self.messages)
	self.title = ""
	self.lastPromptTokens = 0
end

-- Replace the in-memory history (used when reopening a saved session). The loop reads
-- conversation.messages fresh at the start of each Send, so swapping the table here is safe.
function Conversation.load(self: Conversation, title: string, messages: { any })
	self.title = title
	self.messages = messages
	self.lastPromptTokens = 0
end

return Conversation
