--!strict
-- Memory: cross-session memory the agent recalls automatically. Two scopes: "global" (one bucket,
-- carried across every place — the user's preferences + reusable techniques) and "game" (one bucket
-- per game.GameId — THIS place's architecture/conventions/decisions). Persisted via plugin:SetSetting
-- (same mechanism as Config/Sessions). The agent writes via the remember/forget tools; recall is
-- always-on injection (promptBlock appended to the system prompt each Send). One instance in deps.memory.
--
-- DURABLE: writes go straight to SetSetting and are NOT rolled back with the conversation on a
-- non-clean exit (unlike taskList). Memory rides in the SYSTEM prompt (not the message history), so
-- compaction never touches it.

local Memory = {}
Memory.__index = Memory

export type Entry = { id: number, text: string, createdAt: number }

local MAX_ENTRIES = 25
local MAX_TEXT = 240

Memory.MAX_ENTRIES = MAX_ENTRIES
Memory.MAX_TEXT = MAX_TEXT

local SETTING_PREFIX = "StudioAgent_"
local GLOBAL_KEY = SETTING_PREFIX .. "memory_global"

export type Memory = typeof(setmetatable(
	{} :: {
		_plugin: Plugin,
	},
	Memory
))

-- ---- pure helpers (no self, no DataModel — directly unit-testable) ----

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function truncate(s: string, maxChars: number): string
	local len = utf8.len(s)
	if len == nil then
		return string.sub(s, 1, maxChars)
	end
	if len <= maxChars then
		return s
	end
	local byteEnd = utf8.offset(s, maxChars + 1)
	if byteEnd == nil then
		return s
	end
	return string.sub(s, 1, byteEnd - 1)
end

-- Trim + UTF-8-safe truncate; nil if not a non-empty string.
function Memory.normalizeText(text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	local t = trim(text)
	if t == "" then
		return nil
	end
	return truncate(t, MAX_TEXT)
end

-- Append a normalized entry (id = max existing + 1, createdAt = now). FIFO-drop the oldest when over
-- MAX_ENTRIES. Returns (newEntries, note). Invalid text -> unchanged entries + an error note.
function Memory.addTo(entries: { Entry }, text: any, now: number): ({ Entry }, string)
	local normalized = Memory.normalizeText(text)
	if normalized == nil then
		return entries, "remember failed: text must be a non-empty string"
	end
	local maxId = 0
	for _, e in ipairs(entries) do
		if e.id > maxId then
			maxId = e.id
		end
	end
	local out: { Entry } = {}
	for _, e in ipairs(entries) do
		table.insert(out, e)
	end
	local newId = maxId + 1
	table.insert(out, { id = newId, text = normalized, createdAt = now })
	local dropped = 0
	while #out > MAX_ENTRIES do
		table.remove(out, 1)
		dropped += 1
	end
	local note = "remembered (#" .. tostring(newId) .. "); " .. tostring(#out) .. " stored"
	if dropped > 0 then
		note ..= "; dropped " .. tostring(dropped) .. " oldest (cap " .. tostring(MAX_ENTRIES) .. ")"
	end
	return out, note
end

-- Remove the entry with the given id (coerced to a number). Returns (newEntries, removed).
function Memory.forgetFrom(entries: { Entry }, id: any): ({ Entry }, boolean)
	local target = tonumber(id)
	local out: { Entry } = {}
	local removed = false
	for _, e in ipairs(entries) do
		if target ~= nil and e.id == target then
			removed = true
		else
			table.insert(out, e)
		end
	end
	return out, removed
end

-- Render a bucket as "#<id> <text>" lines, or "(none)".
function Memory.renderBucket(entries: { Entry }): string
	if #entries == 0 then
		return "(none)"
	end
	local lines: { string } = {}
	for _, e in ipairs(entries) do
		table.insert(lines, "#" .. tostring(e.id) .. " " .. e.text)
	end
	return table.concat(lines, "\n")
end

-- ---- instance (live store) ----

function Memory.new(plugin: Plugin): Memory
	return setmetatable({ _plugin = plugin }, Memory)
end

local function gameKey(): string
	return SETTING_PREFIX .. "memory_game_" .. tostring(game.GameId)
end

local function normScope(scope: any): string
	if scope == "global" then
		return "global"
	end
	return "game"
end

local function keyFor(scope: string): string
	if scope == "global" then
		return GLOBAL_KEY
	end
	return gameKey()
end

-- Load a bucket's entries, re-normalizing defensively (a corrupt/old blob can't inject junk).
function Memory.loadBucket(self: Memory, scope: string): { Entry }
	local raw = self._plugin:GetSetting(keyFor(scope))
	local out: { Entry } = {}
	if type(raw) == "table" then
		for _, e in ipairs(raw :: { any }) do
			if type(e) == "table" then
				local text = Memory.normalizeText(e.text)
				if text ~= nil and type(e.id) == "number" then
					table.insert(out, {
						id = e.id,
						text = text,
						createdAt = if type(e.createdAt) == "number" then e.createdAt else 0,
					})
				end
			end
		end
	end
	return out
end

-- Add a fact under scope ("global" or "game", default "game"). Persists. Returns a note.
function Memory.add(self: Memory, scope: any, text: any): string
	local s = normScope(scope)
	local entries = self:loadBucket(s)
	local updated, note = Memory.addTo(entries, text, os.time())
	self._plugin:SetSetting(keyFor(s), updated)
	return note .. " [" .. s .. "]"
end

-- Forget an entry by id under scope. Persists. Returns a confirmation.
function Memory.forget(self: Memory, scope: any, id: any): string
	local s = normScope(scope)
	local entries = self:loadBucket(s)
	local updated, removed = Memory.forgetFrom(entries, id)
	if not removed then
		return "no entry #" .. tostring(id) .. " in " .. s .. " memory"
	end
	self._plugin:SetSetting(keyFor(s), updated)
	return "forgot #" .. tostring(id) .. " [" .. s .. "]"
end

function Memory.list(self: Memory, scope: any): { Entry }
	return self:loadBucket(normScope(scope))
end

function Memory.clear(self: Memory, scope: any)
	self._plugin:SetSetting(keyFor(normScope(scope)), {})
end

-- Render BOTH buckets for injection into the system prompt. "" when both empty (inject nothing).
function Memory.promptBlock(self: Memory): string
	local g = self:loadBucket("global")
	local gm = self:loadBucket("game")
	if #g == 0 and #gm == 0 then
		return ""
	end
	return "# Remembered from earlier sessions\n"
		.. "Facts you saved in past chats (recalled automatically). Use forget(scope, id) to drop a stale one.\n\n"
		.. "## Global (every place)\n"
		.. Memory.renderBucket(g)
		.. "\n\n## This game\n"
		.. Memory.renderBucket(gm)
end

return Memory
