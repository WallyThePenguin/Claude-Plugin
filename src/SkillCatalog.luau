--!strict
-- SkillCatalog: PURE helpers for skills (no self, no DataModel — directly unit-testable, the bulk of
-- the logic; mirrors Memory.luau's pure layer). A skill is recipe TEXT the agent executes with its
-- existing tools; use_skill returns the rendered body. Built-ins are code modules; user skills persist
-- (see SkillStore). normalizeName/validateSkill/renderSkill/catalogBlock are shared by SkillStore +
-- Tools/Skills + the Spec.

local SkillCatalog = {}

export type Param = { name: string, description: string, required: boolean }
export type Skill = {
	name: string,
	description: string,
	body: string,
	parameters: { Param },
	category: string, -- "recipe" | "working"
	source: string, -- "builtin" | "user"
}

local MAX_NAME = 48
local MAX_DESC = 200
local MAX_BODY = 6000
local MAX_PARAMS = 8
local MAX_PARAM_FIELD = 200
local MAX_USER_SKILLS = 20

SkillCatalog.MAX_NAME = MAX_NAME
SkillCatalog.MAX_DESC = MAX_DESC
SkillCatalog.MAX_BODY = MAX_BODY
SkillCatalog.MAX_PARAMS = MAX_PARAMS
SkillCatalog.MAX_PARAM_FIELD = MAX_PARAM_FIELD
SkillCatalog.MAX_USER_SKILLS = MAX_USER_SKILLS

-- ---- shared string helpers (UTF-8-safe; same shape as Memory.luau) ----

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

-- Replace EVERY literal occurrence of `find` in `s` with `repl` (NOT a Lua pattern — escapes magic
-- chars, so a param name like "shop-gui" with a magic '-' is replaced literally).
local function literalReplace(s: string, find: string, repl: string): string
	local escaped = (string.gsub(find, "[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
	return (string.gsub(s, escaped, (string.gsub(repl, "%%", "%%%%"))))
end

-- ---- name / param / skill normalization ----

-- Lowercase, trim, collapse non-[a-z0-9] runs to "-", strip leading/trailing "-"; nil if empty.
function SkillCatalog.normalizeName(name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local s = string.lower(trim(name))
	s = (string.gsub(s, "[^a-z0-9]+", "-"))
	s = (string.gsub(s, "^%-+", ""))
	s = (string.gsub(s, "%-+$", ""))
	if s == "" then
		return nil
	end
	return truncate(s, MAX_NAME)
end

-- Defensive: drop malformed entries, trim+truncate fields, coerce required to boolean, cap count.
function SkillCatalog.normalizeParams(raw: any): { Param }
	local out: { Param } = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, item in ipairs(raw :: { any }) do
		if type(item) == "table" and type(item.name) == "string" and trim(item.name) ~= "" then
			local desc = if type(item.description) == "string" then item.description else ""
			table.insert(out, {
				name = truncate(trim(item.name), MAX_PARAM_FIELD),
				description = truncate(trim(desc), MAX_PARAM_FIELD),
				required = item.required == true,
			})
			if #out >= MAX_PARAMS then
				break
			end
		end
	end
	return out
end

-- Validate+normalize a raw skill table into a clean Skill, or (nil, errorString).
function SkillCatalog.validateSkill(raw: any, source: string, category: string): (Skill?, string?)
	if type(raw) ~= "table" then
		return nil, "skill must be a table"
	end
	local name = SkillCatalog.normalizeName(raw.name)
	if name == nil then
		return nil, "skill name must contain at least one letter/digit"
	end
	if type(raw.description) ~= "string" or trim(raw.description) == "" then
		return nil, "skill '" .. name .. "' needs a non-empty description"
	end
	if type(raw.body) ~= "string" or trim(raw.body) == "" then
		return nil, "skill '" .. name .. "' needs a non-empty body"
	end
	return {
		name = name,
		description = truncate(trim(raw.description), MAX_DESC),
		body = truncate(trim(raw.body), MAX_BODY),
		parameters = SkillCatalog.normalizeParams(raw.parameters),
		category = category,
		source = source,
	},
		nil
end

-- Exact (normalized) name lookup.
function SkillCatalog.findByName(skills: { Skill }, name: any): Skill?
	local target = SkillCatalog.normalizeName(name)
	if target == nil then
		return nil
	end
	for _, s in ipairs(skills) do
		if s.name == target then
			return s
		end
	end
	return nil
end

-- Render a skill into the text use_skill returns. Required-param missing -> (errorText, false) BEFORE
-- any build. Substitutes {{param}} placeholders, then appends a Provided-arguments block.
function SkillCatalog.renderSkill(skill: Skill, args: any): (string, boolean)
	local a: { [string]: any } = if type(args) == "table" then args else {}
	local missing: { string } = {}
	for _, p in ipairs(skill.parameters) do
		if p.required and (a[p.name] == nil or a[p.name] == "") then
			table.insert(missing, p.name)
		end
	end
	if #missing > 0 then
		return "skill '"
			.. skill.name
			.. "' needs argument(s): "
			.. table.concat(missing, ", ")
			.. ". Call use_skill again with them in `args`.",
			false
	end
	local body = skill.body
	for _, p in ipairs(skill.parameters) do
		if a[p.name] ~= nil then
			body = literalReplace(body, "{{" .. p.name .. "}}", tostring(a[p.name]))
		end
	end
	local lines = { "# Skill: " .. skill.name, skill.description, "", body }
	if #skill.parameters > 0 then
		table.insert(lines, "")
		table.insert(lines, "## Provided arguments")
		for _, p in ipairs(skill.parameters) do
			local v = if a[p.name] ~= nil then tostring(a[p.name]) else "(not provided)"
			table.insert(lines, "- " .. p.name .. ": " .. v)
		end
	end
	return table.concat(lines, "\n"), true
end

-- Render the always-on catalog (name — description lines, grouped). "" if no skills.
function SkillCatalog.catalogBlock(skills: { Skill }): string
	local recipes: { Skill } = {}
	local working: { Skill } = {}
	local user: { Skill } = {}
	for _, s in ipairs(skills) do
		if s.source == "user" then
			table.insert(user, s)
		elseif s.category == "working" then
			table.insert(working, s)
		else
			table.insert(recipes, s)
		end
	end
	if #recipes == 0 and #working == 0 and #user == 0 then
		return ""
	end
	local out = {
		"# Skills (named recipes you can invoke)",
		"Call use_skill(name, args?) to load a recipe, then FOLLOW it with your normal tools — it returns "
			.. "instructions, not a finished build.",
	}
	local function section(title: string, list: { Skill })
		if #list == 0 then
			return
		end
		table.insert(out, "")
		table.insert(out, "## " .. title)
		for _, s in ipairs(list) do
			table.insert(out, "- " .. s.name .. " — " .. s.description)
		end
	end
	section("Build recipes", recipes)
	section("Working skills (how to approach a task)", working)
	section("Your skills (saved)", user)
	return table.concat(out, "\n")
end

return SkillCatalog
