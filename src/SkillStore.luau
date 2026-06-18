--!strict
-- SkillStore: the live skills store. Merges BUILT-IN skills (code modules, immutable) with USER skills
-- (self-authored, persisted via plugin:SetSetting — same mechanism as Memory). One instance in
-- deps.skills. Built-in names are RESERVED (save rejects a collision; delete refuses a built-in), so
-- the merged catalog has unique names and use_skill is unambiguous. User skills are GLOBAL-scope (one
-- bucket) in v1.

local SkillCatalog = require(script.Parent.SkillCatalog)
local BuiltinRecipes = require(script.Parent.BuiltinRecipes)
local BuiltinWorkingSkills = require(script.Parent.BuiltinWorkingSkills)

type Skill = SkillCatalog.Skill

local SkillStore = {}
SkillStore.__index = SkillStore

local SETTING_PREFIX = "StudioAgent_"
local USER_KEY = SETTING_PREFIX .. "skills_user"

export type SkillStore = typeof(setmetatable(
	{} :: {
		_plugin: Plugin,
		_builtins: { Skill },
		_builtinNames: { [string]: boolean },
	},
	SkillStore
))

-- Validate the built-in lists ONCE at construction; a malformed built-in is dropped + warned (never
-- crashes the plugin).
local function buildBuiltins(): ({ Skill }, { [string]: boolean })
	local out: { Skill } = {}
	local names: { [string]: boolean } = {}
	local function add(rawList: { any }, category: string)
		for _, raw in ipairs(rawList) do
			local skill, err = SkillCatalog.validateSkill(raw, "builtin", category)
			if skill ~= nil and not names[skill.name] then
				names[skill.name] = true
				table.insert(out, skill)
			elseif skill == nil then
				warn("[StudioAgent] skipping malformed built-in skill: " .. tostring(err))
			end
		end
	end
	add(BuiltinRecipes.list, "recipe")
	add(BuiltinWorkingSkills.list, "working")
	return out, names
end

function SkillStore.new(plugin: Plugin): SkillStore
	local builtins, names = buildBuiltins()
	return setmetatable(
		{ _plugin = plugin, _builtins = builtins, _builtinNames = names },
		SkillStore
	)
end

-- Load user skills, re-validating defensively (a corrupt/old blob can't inject junk); drop a name that
-- collides with a built-in or a duplicate; cap to MAX_USER_SKILLS (keep the newest).
function SkillStore.loadUser(self: SkillStore): { Skill }
	local raw = self._plugin:GetSetting(USER_KEY)
	local out: { Skill } = {}
	if type(raw) == "table" then
		local seen: { [string]: boolean } = {}
		for _, e in ipairs(raw :: { any }) do
			local skill = SkillCatalog.validateSkill(e, "user", "recipe")
			if skill ~= nil and not self._builtinNames[skill.name] and not seen[skill.name] then
				seen[skill.name] = true
				table.insert(out, skill)
			end
		end
	end
	while #out > SkillCatalog.MAX_USER_SKILLS do
		table.remove(out, 1)
	end
	return out
end

-- Built-ins first, then user. Used by the catalog + lookup.
function SkillStore.all(self: SkillStore): { Skill }
	local out: { Skill } = {}
	for _, s in ipairs(self._builtins) do
		table.insert(out, s)
	end
	for _, s in ipairs(self:loadUser()) do
		table.insert(out, s)
	end
	return out
end

-- Persist the raw user list (store only the authored fields).
local function persistUser(self: SkillStore, skills: { Skill })
	local raw: { any } = {}
	for _, s in ipairs(skills) do
		table.insert(
			raw,
			{ name = s.name, description = s.description, body = s.body, parameters = s.parameters }
		)
	end
	self._plugin:SetSetting(USER_KEY, raw)
end

-- Save a user skill. Rejects a built-in-name collision; updates an existing same-name user skill in
-- place; FIFO-drops the oldest if over cap. Returns (note, ok).
function SkillStore.save(
	self: SkillStore,
	name: any,
	description: any,
	body: any,
	parameters: any
): (string, boolean)
	local skill, err = SkillCatalog.validateSkill(
		{ name = name, description = description, body = body, parameters = parameters },
		"user",
		"recipe"
	)
	if skill == nil then
		return "save_skill failed: " .. tostring(err), false
	end
	if self._builtinNames[skill.name] then
		return "save_skill failed: '" .. skill.name .. "' is a built-in skill name (pick another).",
			false
	end
	local users = self:loadUser()
	local replaced = false
	for i, s in ipairs(users) do
		if s.name == skill.name then
			users[i] = skill
			replaced = true
			break
		end
	end
	if not replaced then
		table.insert(users, skill)
	end
	local dropped = 0
	while #users > SkillCatalog.MAX_USER_SKILLS do
		table.remove(users, 1)
		dropped += 1
	end
	persistUser(self, users)
	local note = if replaced
		then "updated skill '" .. skill.name .. "'"
		else "saved skill '" .. skill.name .. "'"
	note ..= " (" .. tostring(#users) .. " of your skills stored)"
	if dropped > 0 then
		note ..= "; dropped " .. tostring(dropped) .. " oldest (cap " .. tostring(
			SkillCatalog.MAX_USER_SKILLS
		) .. ")"
	end
	return note, true
end

-- Delete a USER skill by name. Refuses a built-in. Returns (note, ok).
function SkillStore.delete(self: SkillStore, name: any): (string, boolean)
	local n = SkillCatalog.normalizeName(name)
	if n == nil then
		return "delete_skill: invalid name", false
	end
	if self._builtinNames[n] then
		return "delete_skill: '" .. n .. "' is a built-in skill and can't be deleted.", false
	end
	local users = self:loadUser()
	local kept: { Skill } = {}
	local removed = false
	for _, s in ipairs(users) do
		if s.name == n then
			removed = true
		else
			table.insert(kept, s)
		end
	end
	if not removed then
		return "delete_skill: no skill named '" .. n .. "'", false
	end
	persistUser(self, kept)
	return "deleted skill '" .. n .. "'", true
end

-- Resolve name+args into the recipe text use_skill returns. (text, ok).
function SkillStore.resolve(self: SkillStore, name: any, args: any): (string, boolean)
	local skill = SkillCatalog.findByName(self:all(), name)
	if skill == nil then
		return "unknown skill '" .. tostring(name) .. "'. See the skill catalog for valid names.",
			false
	end
	return SkillCatalog.renderSkill(skill, args)
end

function SkillStore.listBuiltins(self: SkillStore): { Skill }
	return self._builtins
end

function SkillStore.listUser(self: SkillStore): { Skill }
	return self:loadUser()
end

-- The always-on catalog injected into the leading preamble.
function SkillStore.catalogBlock(self: SkillStore): string
	return SkillCatalog.catalogBlock(self:all())
end

return SkillStore
