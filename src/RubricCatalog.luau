--!strict
-- RubricCatalog: PURE helpers for quality rubrics (no self, no DataModel — directly unit-testable;
-- mirrors SkillCatalog/Memory's pure layer). A rubric is the graded quality bar for an asset category;
-- the agent loads it via use_rubric and builds to the highest tier. validateRubric/render/catalogBlock/
-- findByCategory are shared by RubricStore + Tools/Rubrics + the Spec.

local RubricCatalog = {}

export type Grading = { pass: string, partial: string, fail: string }
export type Criterion = {
	id: string,
	order_index: number,
	tier: string, -- "baseline" | "good" | "exceptional"
	statement: string,
	above_generic_rationale: string,
	grading: Grading,
	evidence_required: string,
	concrete_fix: string,
	exemplar_refs: { string },
}
export type Rubric = {
	module: string,
	version: string,
	system_module: string,
	criteria: { Criterion },
}

local TIERS: { [string]: boolean } = { baseline = true, good = true, exceptional = true }
local TIER_ORDER = { "baseline", "good", "exceptional" }
local TIER_TITLE: { [string]: string } = {
	baseline = "Baseline",
	good = "Good (above the mean)",
	exceptional = "Exceptional (polish)",
}

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Normalize a category name for matching against rubric.module: lowercase + trim; nil if empty.
function RubricCatalog.normalizeCategory(name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local s = string.lower(trim(name))
	if s == "" then
		return nil
	end
	return s
end

local function tierCounts(rubric: Rubric): { [string]: number }
	local n: { [string]: number } = { baseline = 0, good = 0, exceptional = 0 }
	for _, c in ipairs(rubric.criteria) do
		n[c.tier] = (n[c.tier] or 0) + 1
	end
	return n
end

-- Validate ONE decoded rubric table into a clean Rubric, or (nil, errorString). Defensive so a
-- malformed built-in is dropped at load (never crashes the plugin).
function RubricCatalog.validateRubric(raw: any): (Rubric?, string?)
	if type(raw) ~= "table" then
		return nil, "rubric must be a table"
	end
	if type(raw.module) ~= "string" or trim(raw.module) == "" then
		return nil, "rubric needs a non-empty 'module'"
	end
	if type(raw.criteria) ~= "table" or #raw.criteria == 0 then
		return nil, "rubric '" .. raw.module .. "' needs a non-empty 'criteria' array"
	end
	local criteria: { Criterion } = {}
	for i, c in ipairs(raw.criteria :: { any }) do
		if type(c) ~= "table" then
			return nil,
				"rubric '" .. raw.module .. "' criterion " .. tostring(i) .. " is not a table"
		end
		local g = c.grading
		if
			type(c.id) ~= "string"
			or type(c.tier) ~= "string"
			or not TIERS[c.tier]
			or type(c.statement) ~= "string"
			or type(g) ~= "table"
			or type(g.pass) ~= "string"
			or type(g.partial) ~= "string"
			or type(g.fail) ~= "string"
		then
			return nil,
				"rubric '" .. raw.module .. "' criterion " .. tostring(c.id) .. " is malformed"
		end
		local refs: { string } = {}
		if type(c.exemplar_refs) == "table" then
			for _, r in ipairs(c.exemplar_refs :: { any }) do
				if type(r) == "string" then
					table.insert(refs, r)
				end
			end
		end
		table.insert(criteria, {
			id = c.id,
			order_index = if type(c.order_index) == "number" then c.order_index else i,
			tier = c.tier,
			statement = c.statement,
			above_generic_rationale = if type(c.above_generic_rationale) == "string"
				then c.above_generic_rationale
				else "",
			grading = { pass = g.pass, partial = g.partial, fail = g.fail },
			evidence_required = if type(c.evidence_required) == "string"
				then c.evidence_required
				else "",
			concrete_fix = if type(c.concrete_fix) == "string" then c.concrete_fix else "",
			exemplar_refs = refs,
		})
	end
	table.sort(criteria, function(a, b)
		return a.order_index < b.order_index
	end)
	local moduleLower = string.lower(trim(raw.module))
	return {
		module = moduleLower,
		version = if type(raw.version) == "string" then raw.version else "1",
		system_module = if type(raw.system_module) == "string"
			then raw.system_module
			else moduleLower,
		criteria = criteria,
	},
		nil
end

-- Exact (normalized) category lookup against rubric.module.
function RubricCatalog.findByCategory(rubrics: { Rubric }, category: any): Rubric?
	local target = RubricCatalog.normalizeCategory(category)
	if target == nil then
		return nil
	end
	for _, r in ipairs(rubrics) do
		if r.module == target then
			return r
		end
	end
	return nil
end

-- Render the full rubric text use_rubric returns (tiered).
function RubricCatalog.render(rubric: Rubric): string
	local n = tierCounts(rubric)
	local out: { string } = {
		"# Quality rubric: " .. rubric.module .. " (v" .. rubric.version .. ")",
		"Build to the HIGHEST tier you can; for each criterion address its concrete_fix. Tiers: "
			.. tostring(n.baseline)
			.. " baseline / "
			.. tostring(n.good)
			.. " good / "
			.. tostring(n.exceptional)
			.. " exceptional.",
	}
	for _, tier in ipairs(TIER_ORDER) do
		local headerDone = false
		for _, c in ipairs(rubric.criteria) do
			if c.tier == tier then
				if not headerDone then
					table.insert(out, "")
					table.insert(out, "## " .. TIER_TITLE[tier])
					headerDone = true
				end
				table.insert(out, "")
				table.insert(out, "### " .. c.id)
				table.insert(out, c.statement)
				if c.above_generic_rationale ~= "" then
					table.insert(out, "- Why above generic: " .. c.above_generic_rationale)
				end
				table.insert(out, "- Pass: " .. c.grading.pass)
				table.insert(out, "- Partial: " .. c.grading.partial)
				table.insert(out, "- Fail: " .. c.grading.fail)
				if c.evidence_required ~= "" then
					table.insert(out, "- Evidence required: " .. c.evidence_required)
				end
				if c.concrete_fix ~= "" then
					table.insert(out, "- Concrete fix: " .. c.concrete_fix)
				end
				if #c.exemplar_refs > 0 then
					table.insert(out, "- Exemplar refs: " .. table.concat(c.exemplar_refs, ", "))
				end
			end
		end
	end
	return table.concat(out, "\n")
end

-- Always-on compact catalog (one line per rubric). "" if none.
function RubricCatalog.catalogBlock(rubrics: { Rubric }): string
	if #rubrics == 0 then
		return ""
	end
	local out: { string } = {
		"# Quality rubrics (build to the bar)",
		"Curated above-the-mean quality rubrics per asset category. BEFORE building an asset in a "
			.. "listed category, call use_rubric(category) to load its full tiered rubric, then build to "
			.. "the highest tier you can and address each criterion's concrete_fix.",
		"",
	}
	for _, r in ipairs(rubrics) do
		local n = tierCounts(r)
		table.insert(
			out,
			"- "
				.. r.module
				.. " — "
				.. tostring(#r.criteria)
				.. " criteria ("
				.. tostring(n.baseline)
				.. " baseline / "
				.. tostring(n.good)
				.. " good / "
				.. tostring(n.exceptional)
				.. " exceptional)"
		)
	end
	return table.concat(out, "\n")
end

return RubricCatalog
