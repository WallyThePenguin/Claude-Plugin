--!strict
-- BuildGuideCatalog: PURE helpers for build guides (no self, no DataModel — directly unit-testable;
-- mirrors RubricCatalog's pure layer). A build guide is the proactive twin of a rubric: the rubric
-- GRADES, the guide BUILDS. The agent loads it via use_build_guide and follows the tiered steps.
-- validateGuide/render/catalogBlock/findByCategory are shared by BuildGuideStore + Tools/BuildGuides + Spec.

local BuildGuideCatalog = {}

export type Step = {
	id: string,
	order_index: number,
	instruction: string,
	addresses_criteria: { string },
	tools: { string },
	pitfalls: string,
}
export type Tier = {
	tier: string, -- "baseline" | "good" | "exceptional"
	goal: string,
	steps: { Step },
}
export type KillerSystem = { name: string, what: string, how: string }
export type Coverage = { total: number, addressed: number }
export type Guide = {
	module: string,
	version: string,
	system_module: string,
	rubric_version: string,
	overview: string,
	killer_systems: { KillerSystem },
	tiers: { Tier },
	common_pitfalls: { string },
	coverage: Coverage?,
}

local TIERS: { [string]: boolean } = { baseline = true, good = true, exceptional = true }
local TIER_ORDER = { "baseline", "good", "exceptional" }
local TIER_RANK: { [string]: number } = { baseline = 1, good = 2, exceptional = 3 }
local TIER_TITLE: { [string]: string } = {
	baseline = "Baseline",
	good = "Good (above the mean)",
	exceptional = "Exceptional (polish)",
}

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Normalize a category name for matching against guide.module: lowercase + trim; nil if empty.
function BuildGuideCatalog.normalizeCategory(name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local s = string.lower(trim(name))
	if s == "" then
		return nil
	end
	return s
end

local function strArray(raw: any): { string }
	local out: { string } = {}
	if type(raw) == "table" then
		for _, v in ipairs(raw :: { any }) do
			if type(v) == "string" then
				table.insert(out, v)
			end
		end
	end
	return out
end

local function str(raw: any): string
	return if type(raw) == "string" then raw else ""
end

-- Validate ONE decoded guide table into a clean Guide, or (nil, errorString). Defensive so a malformed
-- built-in is dropped at load (never crashes the plugin). Mirrors RubricCatalog.validateRubric.
function BuildGuideCatalog.validateGuide(raw: any): (Guide?, string?)
	if type(raw) ~= "table" then
		return nil, "build guide must be a table"
	end
	if type(raw.module) ~= "string" or trim(raw.module) == "" then
		return nil, "build guide needs a non-empty 'module'"
	end
	if type(raw.tiers) ~= "table" or #raw.tiers == 0 then
		return nil, "build guide '" .. raw.module .. "' needs a non-empty 'tiers' array"
	end
	local tiers: { Tier } = {}
	for ti, t in ipairs(raw.tiers :: { any }) do
		if type(t) ~= "table" or type(t.tier) ~= "string" or not TIERS[t.tier] then
			return nil,
				"build guide '" .. raw.module .. "' tier " .. tostring(ti) .. " is malformed"
		end
		if type(t.steps) ~= "table" then
			return nil,
				"build guide '" .. raw.module .. "' tier '" .. t.tier .. "' needs a 'steps' array"
		end
		local steps: { Step } = {}
		for si, s in ipairs(t.steps :: { any }) do
			if type(s) ~= "table" or type(s.id) ~= "string" or type(s.instruction) ~= "string" then
				return nil,
					"build guide '" .. raw.module .. "' tier '" .. t.tier .. "' step " .. tostring(
						si
					) .. " needs an id + instruction"
			end
			table.insert(steps, {
				id = s.id,
				order_index = if type(s.order_index) == "number" then s.order_index else si,
				instruction = s.instruction,
				addresses_criteria = strArray(s.addresses_criteria),
				tools = strArray(s.tools),
				pitfalls = str(s.pitfalls),
			})
		end
		table.sort(steps, function(a, b)
			return a.order_index < b.order_index
		end)
		table.insert(tiers, { tier = t.tier, goal = str(t.goal), steps = steps })
	end
	table.sort(tiers, function(a, b)
		return (TIER_RANK[a.tier] or 9) < (TIER_RANK[b.tier] or 9)
	end)
	local killers: { KillerSystem } = {}
	if type(raw.killer_systems) == "table" then
		for _, k in ipairs(raw.killer_systems :: { any }) do
			if type(k) == "table" and type(k.name) == "string" then
				table.insert(killers, { name = k.name, what = str(k.what), how = str(k.how) })
			end
		end
	end
	local coverage: Coverage? = nil
	if type(raw.provenance) == "table" and type(raw.provenance.coverage) == "table" then
		local c = raw.provenance.coverage
		if type(c.criteria_total) == "number" and type(c.criteria_addressed) == "number" then
			coverage = { total = c.criteria_total, addressed = c.criteria_addressed }
		end
	end
	local moduleLower = string.lower(trim(raw.module))
	return {
		module = moduleLower,
		version = if type(raw.version) == "string" then raw.version else "1",
		system_module = if type(raw.system_module) == "string"
			then raw.system_module
			else moduleLower,
		rubric_version = str(raw.rubric_version),
		overview = str(raw.overview),
		killer_systems = killers,
		tiers = tiers,
		common_pitfalls = strArray(raw.common_pitfalls),
		coverage = coverage,
	},
		nil
end

-- User-guide cap (newest kept), mirroring SkillCatalog.MAX_USER_SKILLS.
local MAX_USER_GUIDES = 20
BuildGuideCatalog.MAX_USER_GUIDES = MAX_USER_GUIDES

-- Insert-or-update a VALIDATED user guide into the user list. Rejects a reserved (built-in) module;
-- replaces a same-module user guide in place; FIFO-drops the oldest past MAX_USER_GUIDES. PURE (no
-- DataModel) so it is unit-testable; the store wires plugin:GetSetting/SetSetting around it. Returns
-- (newList, note, ok). Mirrors SkillStore.save's logic.
function BuildGuideCatalog.saveInto(
	userGuides: { Guide },
	guide: Guide,
	reserved: { [string]: boolean }
): ({ Guide }, string, boolean)
	if reserved[guide.module] then
		return userGuides,
			"save_build_guide failed: '"
				.. guide.module
				.. "' is a built-in guide category (pick another).",
			false
	end
	local out: { Guide } = {}
	local replaced = false
	for _, g in ipairs(userGuides) do
		if g.module == guide.module then
			table.insert(out, guide)
			replaced = true
		else
			table.insert(out, g)
		end
	end
	if not replaced then
		table.insert(out, guide)
	end
	local dropped = 0
	while #out > MAX_USER_GUIDES do
		table.remove(out, 1)
		dropped += 1
	end
	local note = if replaced
		then "updated build guide '" .. guide.module .. "'"
		else "saved build guide '" .. guide.module .. "'"
	note ..= " (" .. tostring(#out) .. " of your guides stored)"
	if dropped > 0 then
		note ..= "; dropped " .. tostring(dropped) .. " oldest (cap " .. tostring(MAX_USER_GUIDES) .. ")"
	end
	return out, note, true
end

-- Remove a USER guide by module/category. PURE. Returns (newList, note, ok).
function BuildGuideCatalog.deleteFrom(
	userGuides: { Guide },
	module: any
): ({ Guide }, string, boolean)
	local target = BuildGuideCatalog.normalizeCategory(module)
	if target == nil then
		return userGuides, "delete_build_guide: invalid category", false
	end
	local out: { Guide } = {}
	local removed = false
	for _, g in ipairs(userGuides) do
		if g.module == target then
			removed = true
		else
			table.insert(out, g)
		end
	end
	if not removed then
		return userGuides, "delete_build_guide: no user guide for '" .. target .. "'", false
	end
	return out, "deleted build guide '" .. target .. "'", true
end

-- Exact (normalized) category lookup against guide.module.
function BuildGuideCatalog.findByCategory(guides: { Guide }, category: any): Guide?
	local target = BuildGuideCatalog.normalizeCategory(category)
	if target == nil then
		return nil
	end
	for _, g in ipairs(guides) do
		if g.module == target then
			return g
		end
	end
	return nil
end

local function stepCount(guide: Guide): number
	local n = 0
	for _, t in ipairs(guide.tiers) do
		n += #t.steps
	end
	return n
end

-- Render the full guide text use_build_guide returns (tiered, ordered steps).
function BuildGuideCatalog.render(guide: Guide): string
	local header = "# Build guide: " .. guide.module .. " (v" .. guide.version .. ")"
	if guide.rubric_version ~= "" then
		header ..= " — targets the rubric (v" .. guide.rubric_version .. ")"
	end
	local out: { string } = { header }
	if guide.overview ~= "" then
		table.insert(out, guide.overview)
	end
	if #guide.killer_systems > 0 then
		local parts: { string } = {}
		for _, k in ipairs(guide.killer_systems) do
			local p = k.name
			if k.what ~= "" then
				p ..= " — " .. k.what
			end
			if k.how ~= "" then
				p ..= " (" .. k.how .. ")"
			end
			table.insert(parts, p)
		end
		table.insert(out, "Killer systems: " .. table.concat(parts, "; "))
	end
	for _, tier in ipairs(TIER_ORDER) do
		for _, t in ipairs(guide.tiers) do
			if t.tier == tier then
				table.insert(out, "")
				local h = "## " .. TIER_TITLE[tier]
				if t.goal ~= "" then
					h ..= " — " .. t.goal
				end
				table.insert(out, h)
				for i, s in ipairs(t.steps) do
					local line = tostring(i) .. ". " .. s.instruction
					if #s.addresses_criteria > 0 then
						line ..= "  [addresses: " .. table.concat(s.addresses_criteria, ", ") .. "]"
					end
					if #s.tools > 0 then
						line ..= "  [tools: " .. table.concat(s.tools, ", ") .. "]"
					end
					table.insert(out, line)
					if s.pitfalls ~= "" then
						table.insert(out, "   Pitfall: " .. s.pitfalls)
					end
				end
			end
		end
	end
	if #guide.common_pitfalls > 0 then
		table.insert(out, "")
		table.insert(out, "Common pitfalls: " .. table.concat(guide.common_pitfalls, "; "))
	end
	if guide.coverage ~= nil then
		table.insert(
			out,
			"Coverage: "
				.. tostring(guide.coverage.addressed)
				.. "/"
				.. tostring(guide.coverage.total)
				.. " rubric criteria addressed."
		)
	end
	return table.concat(out, "\n")
end

-- Always-on compact catalog (one line per guide). "" if none.
function BuildGuideCatalog.catalogBlock(guides: { Guide }): string
	if #guides == 0 then
		return ""
	end
	local out: { string } = {
		"# Build guides (how to build to the bar)",
		"For an asset category that has a rubric, call use_build_guide(category) to load its tiered BUILD "
			.. "approach — the steps (each citing real tools + the rubric criteria they satisfy) that take a "
			.. "build from baseline to exceptional. Pair it with use_rubric(category): the rubric is the bar, "
			.. "the build guide is how to reach it.",
		"",
	}
	for _, g in ipairs(guides) do
		local line = "- "
			.. g.module
			.. " — "
			.. tostring(stepCount(g))
			.. " steps across "
			.. tostring(#g.tiers)
			.. " tiers"
		if g.coverage ~= nil then
			line ..= " (covers " .. tostring(g.coverage.addressed) .. "/" .. tostring(
				g.coverage.total
			) .. " rubric criteria)"
		end
		table.insert(out, line)
	end
	return table.concat(out, "\n")
end

return BuildGuideCatalog
