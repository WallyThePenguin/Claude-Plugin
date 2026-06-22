--!strict
-- Learnings: per-CATEGORY, GLOBAL, high-priority quality-loop corrections the agent recalls automatically.
-- Distinct from Memory (this-game architecture / general global techniques): a learning is a confirmed lesson
-- for an asset CATEGORY (the rubric categories, e.g. "locomotion") -- "the grader fails builds without runtime
-- foot IK". The agent records via the learn tool AFTER evaluate catches a miss and it fixes it; learnings ride
-- the leading preamble as a "# Priority learnings (apply first)" block; evaluate folds the graded category's
-- learnings into its grade prompt. Persisted via plugin:SetSetting: one key per category
-- (StudioAgent_learnings_<category>) + an index key (the known category names) so promptBlock can enumerate
-- without scanning settings. Mirrors Memory's pure+instance split + corrupt-blob defense. DURABLE (writes go
-- straight to SetSetting; not rolled back with the conversation; the preamble carrying them is rebuilt per send
-- and is NOT in conversation.messages, so compaction never touches them).

local Learnings = {}
Learnings.__index = Learnings

export type Entry = { id: number, text: string, createdAt: number }

local MAX_PER_CATEGORY = 15
local MAX_TEXT = 280
local MAX_CATEGORIES = 24

Learnings.MAX_PER_CATEGORY = MAX_PER_CATEGORY
Learnings.MAX_TEXT = MAX_TEXT

local SETTING_PREFIX = "StudioAgent_"
local INDEX_KEY = SETTING_PREFIX .. "learnings_index"

export type Learnings = typeof(setmetatable(
	{} :: {
		_plugin: Plugin,
	},
	Learnings
))

-- ---- pure helpers (no self, no DataModel -- directly unit-testable) ----

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
function Learnings.normalizeText(text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	local t = trim(text)
	if t == "" then
		return nil
	end
	return truncate(t, MAX_TEXT)
end

-- Lowercase + trim a category; nil if empty/not a string. (Categories align with rubric.module names.)
function Learnings.normalizeCategory(name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local c = string.lower(trim(name))
	if c == "" then
		return nil
	end
	return c
end

-- Append a normalized entry (id = max existing + 1, createdAt = now). FIFO-drop oldest over MAX_PER_CATEGORY.
-- Returns (newEntries, note). Invalid text -> unchanged entries + an error note.
function Learnings.addTo(entries: { Entry }, text: any, now: number): ({ Entry }, string)
	local normalized = Learnings.normalizeText(text)
	if normalized == nil then
		return entries, "learn failed: text must be a non-empty string"
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
	while #out > MAX_PER_CATEGORY do
		table.remove(out, 1)
		dropped += 1
	end
	local note = "learned (#" .. tostring(newId) .. "); " .. tostring(#out) .. " stored"
	if dropped > 0 then
		note ..= "; dropped " .. tostring(dropped) .. " oldest (cap " .. tostring(MAX_PER_CATEGORY) .. ")"
	end
	return out, note
end

-- Remove the entry with the given id (coerced to a number). Returns (newEntries, removed).
function Learnings.forgetFrom(entries: { Entry }, id: any): ({ Entry }, boolean)
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

-- Validate ONE raw stored item into an Entry, or nil. id must be a FINITE POSITIVE INTEGER (corrupt-blob defense).
function Learnings.normalizeEntry(raw: any): Entry?
	if type(raw) ~= "table" then
		return nil
	end
	local text = Learnings.normalizeText(raw.text)
	if text == nil then
		return nil
	end
	local id = raw.id
	if
		type(id) ~= "number"
		or id ~= id
		or id == math.huge
		or id == -math.huge
		or id <= 0
		or id ~= math.floor(id)
	then
		return nil
	end
	local createdAt = if type(raw.createdAt) == "number" then raw.createdAt else 0
	return { id = id, text = text, createdAt = createdAt }
end

-- Render one category's entries as "#<id> <text>" lines, or "(none)".
function Learnings.renderCategory(entries: { Entry }): string
	if #entries == 0 then
		return "(none)"
	end
	local lines: { string } = {}
	for _, e in ipairs(entries) do
		table.insert(lines, "#" .. tostring(e.id) .. " " .. e.text)
	end
	return table.concat(lines, "\n")
end

-- Normalize a raw index value into a clean, de-duped, capped list of category names.
function Learnings.normalizeIndex(raw: any): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	if type(raw) == "table" then
		for _, n in ipairs(raw :: { any }) do
			local c = Learnings.normalizeCategory(n)
			if c ~= nil and not seen[c] then
				seen[c] = true
				table.insert(out, c)
				if #out >= MAX_CATEGORIES then
					break
				end
			end
		end
	end
	return out
end

-- ---- instance (live store) ----

function Learnings.new(plugin: Plugin): Learnings
	return setmetatable({ _plugin = plugin }, Learnings)
end

local function catKey(category: string): string
	return SETTING_PREFIX .. "learnings_" .. category
end

function Learnings.loadIndex(self: Learnings): { string }
	return Learnings.normalizeIndex(self._plugin:GetSetting(INDEX_KEY))
end

local function saveIndex(self: Learnings, names: { string })
	self._plugin:SetSetting(INDEX_KEY, Learnings.normalizeIndex(names))
end

-- Load one category's entries, re-normalizing defensively + capping to MAX_PER_CATEGORY (keep newest).
function Learnings.loadBucket(self: Learnings, category: string): { Entry }
	local raw = self._plugin:GetSetting(catKey(category))
	local out: { Entry } = {}
	if type(raw) == "table" then
		local seen: { [number]: boolean } = {}
		for _, e in ipairs(raw :: { any }) do
			local entry = Learnings.normalizeEntry(e)
			if entry ~= nil and not seen[entry.id] then
				seen[entry.id] = true
				table.insert(out, entry)
			end
		end
	end
	while #out > MAX_PER_CATEGORY do
		table.remove(out, 1)
	end
	return out
end

-- Add a learning under a category. Persists the bucket + ensures the category is in the index. Returns a note.
function Learnings.add(self: Learnings, category: any, text: any): string
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return "learn failed: category must be a non-empty string"
	end
	local entries = self:loadBucket(c)
	local updated, note = Learnings.addTo(entries, text, os.time())
	-- Identity, NOT count: addTo returns the SAME table on invalid text (nothing added) and a NEW table
	-- on success. A count check (#updated == #entries) wrongly matches a VALID add into a full bucket
	-- (append then FIFO-drop nets the same length) and would silently skip the SetSetting -> lost learning.
	if updated == entries then
		-- nothing added (invalid text) -> don't touch storage/index
		return note .. " [" .. c .. "]"
	end
	self._plugin:SetSetting(catKey(c), updated)
	local index = self:loadIndex()
	local present = false
	for _, n in ipairs(index) do
		if n == c then
			present = true
			break
		end
	end
	if not present then
		table.insert(index, c)
		saveIndex(self, index)
	end
	return note .. " [" .. c .. "]"
end

-- Forget a learning by id under a category. Persists. Returns a confirmation.
function Learnings.forget(self: Learnings, category: any, id: any): string
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return "unlearn failed: category must be a non-empty string"
	end
	local entries = self:loadBucket(c)
	local updated, removed = Learnings.forgetFrom(entries, id)
	if not removed then
		return "no learning #" .. tostring(id) .. " in '" .. c .. "'"
	end
	self._plugin:SetSetting(catKey(c), updated)
	return "unlearned #" .. tostring(id) .. " [" .. c .. "]"
end

function Learnings.list(self: Learnings, category: any): { Entry }
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return {}
	end
	return self:loadBucket(c)
end

-- The category names that currently have at least one learning (index ∩ non-empty buckets).
function Learnings.categories(self: Learnings): { string }
	local out: { string } = {}
	for _, c in ipairs(self:loadIndex()) do
		if #self:loadBucket(c) > 0 then
			table.insert(out, c)
		end
	end
	return out
end

-- One category's rendered learnings (for evaluate's grade prompt). "" if none.
function Learnings.forCategory(self: Learnings, category: any): string
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return ""
	end
	local entries = self:loadBucket(c)
	if #entries == 0 then
		return ""
	end
	return Learnings.renderCategory(entries)
end

-- The always-on preamble block: ALL categories' learnings, grouped + capped. "" when none.
function Learnings.promptBlock(self: Learnings): string
	local cats = self:categories()
	if #cats == 0 then
		return ""
	end
	local parts: { string } = {
		"# Priority learnings (apply these first)",
		"Lessons you CONFIRMED in past builds, per asset category. When you build in one of these categories, "
			.. "apply its learnings FIRST -- they override your defaults. Use unlearn(category, id) to drop a "
			.. "stale one.",
	}
	for _, c in ipairs(cats) do
		table.insert(parts, "")
		table.insert(parts, "## " .. c)
		table.insert(parts, Learnings.renderCategory(self:loadBucket(c)))
	end
	return table.concat(parts, "\n")
end

return Learnings
