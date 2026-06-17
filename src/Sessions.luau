--!strict
-- Sessions (M9): persistence + history for chat sessions, via plugin:SetSetting/GetSetting (which
-- stores JSON-serializable values per plugin, surviving Studio restarts). An index holds compact
-- {id,title,updatedAt} metadata (most-recent first); each session's messages live under their own
-- key. Image blocks are stripped to a text placeholder on save (keeps the stored blob small; the
-- screenshot pixels are ephemeral verification, not needed in reloaded history).

local HttpService = game:GetService("HttpService")

local MessageUtil = require(script.Parent.MessageUtil)

local Sessions = {}
Sessions.__index = Sessions

local INDEX_KEY = "StudioAgent_sessionIndex"
local SESSION_PREFIX = "StudioAgent_session_"
local MAX_SESSIONS = 50

export type Meta = { id: string, title: string, updatedAt: number }

export type Sessions = typeof(setmetatable({} :: { _plugin: Plugin }, Sessions))

function Sessions.new(plugin: Plugin): Sessions
	return setmetatable({ _plugin = plugin }, Sessions)
end

function Sessions.newId(_self: Sessions): string
	return HttpService:GenerateGUID(false)
end

local function readIndex(self: Sessions): { Meta }
	local raw = self._plugin:GetSetting(INDEX_KEY)
	if type(raw) == "table" then
		return raw :: { Meta }
	end
	return {}
end

-- Most-recent-first metadata list for the history UI.
function Sessions.list(self: Sessions): { Meta }
	return readIndex(self)
end

-- Persist a conversation under `id` and move it to the front of the index. No-op for an empty chat.
-- `tasks` is the conversation's checklist (taskList:snapshot()) — a plain JSON-safe array; defaults to
-- empty so an older caller / empty checklist persists cleanly.
function Sessions.save(self: Sessions, conversation: any, id: string, tasks: { any }?)
	if #conversation.messages == 0 then
		return
	end
	local title = if conversation.title ~= "" then conversation.title else "(untitled)"
	local updatedAt = os.time()

	self._plugin:SetSetting(SESSION_PREFIX .. id, {
		id = id,
		title = title,
		updatedAt = updatedAt,
		messages = MessageUtil.stripImages(conversation.messages),
		tasks = tasks or {},
	})

	local index = readIndex(self)
	local rebuilt: { Meta } = { { id = id, title = title, updatedAt = updatedAt } }
	for _, meta in index do
		if meta.id ~= id then
			table.insert(rebuilt, meta)
		end
	end
	while #rebuilt > MAX_SESSIONS do
		rebuilt[#rebuilt] = nil
	end
	self._plugin:SetSetting(INDEX_KEY, rebuilt)
end

-- Load a saved session's title + messages + checklist (to rebuild a Conversation + TaskList), or nil
-- if missing. `tasks` defaults to {} for sessions saved before task tracking existed.
function Sessions.load(
	self: Sessions,
	id: string
): { title: string, messages: { any }, tasks: { any } }?
	local raw = self._plugin:GetSetting(SESSION_PREFIX .. id)
	if type(raw) ~= "table" then
		return nil
	end
	return { title = raw.title or "", messages = raw.messages or {}, tasks = raw.tasks or {} }
end

function Sessions.delete(self: Sessions, id: string)
	self._plugin:SetSetting(SESSION_PREFIX .. id, nil)
	local index = readIndex(self)
	local rebuilt: { Meta } = {}
	for _, meta in index do
		if meta.id ~= id then
			table.insert(rebuilt, meta)
		end
	end
	self._plugin:SetSetting(INDEX_KEY, rebuilt)
end

return Sessions
