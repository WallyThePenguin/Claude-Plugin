--!strict
-- EvaluateReport: PURE helpers for the Evaluate tool (no DataModel, no services — directly unit-testable).
-- buildGradeTool turns a Rubric into the forced `submit_grade` tool (schema = one grade per criterion);
-- validateGrades coerces the model's structured output to the rubric's criteria (missing -> "ungraded");
-- renderReport turns validated grades into a readable, fails-first report citing each criterion's concrete_fix.

local RubricCatalog = require(script.Parent.RubricCatalog)

type Rubric = RubricCatalog.Rubric

local EvaluateReport = {}

export type Grade = { id: string, tier: string, towardFull: boolean, evidence: string, gap: string }
export type Validated = { grades: { Grade }, summary: string }

local ALLOWED_TIER: { [string]: boolean } = { fail = true, partial = true, pass = true }
local TIER_GLYPH: { [string]: string } =
	{ pass = "PASS", partial = "PARTIAL", fail = "FAIL", ungraded = "?" }
-- fails first, then partial, then ungraded, then pass
local TIER_RANK: { [string]: number } = { fail = 0, partial = 1, ungraded = 2, pass = 3 }

-- The forced grading tool: the model MUST call submit_grade with one entry per criterion id.
function EvaluateReport.buildGradeTool(rubric: Rubric): { [string]: any }
	local ids: { string } = {}
	for _, c in ipairs(rubric.criteria) do
		table.insert(ids, c.id)
	end
	return {
		name = "submit_grade",
		description = "Submit the per-criterion grade for this rubric. Provide EXACTLY one entry per "
			.. "criterion id; tier is fail|partial|pass; cite the specific evidence; set towardFull only "
			.. "when the exceptional/ceiling extras are also met.",
		input_schema = {
			type = "object",
			properties = {
				grades = {
					type = "array",
					description = "One grade per rubric criterion.",
					items = {
						type = "object",
						properties = {
							id = {
								type = "string",
								enum = ids,
								description = "The rubric criterion id.",
							},
							tier = {
								type = "string",
								enum = { "fail", "partial", "pass" },
								description = "fail | partial | pass against the criterion's Pass definition.",
							},
							towardFull = {
								type = "boolean",
								description = "True if the exceptional/ceiling extras are also met.",
							},
							evidence = {
								type = "string",
								description = "The specific structural/design/visual evidence justifying the tier.",
							},
							gap = {
								type = "string",
								description = "What is missing to reach pass / full marks ('' if pass+towardFull).",
							},
						},
						required = { "id", "tier", "evidence" },
					},
				},
				summary = { type = "string", description = "A 1-2 sentence overall read." },
			},
			required = { "grades", "summary" },
		},
	}
end

-- Coerce the model's raw structured output to one Grade per rubric criterion (in rubric order). Total.
function EvaluateReport.validateGrades(raw: any, rubric: Rubric): Validated
	local byId: { [string]: Grade } = {}
	if type(raw) == "table" and type(raw.grades) == "table" then
		for _, g in ipairs(raw.grades :: { any }) do
			if type(g) == "table" and type(g.id) == "string" then
				local tier = if type(g.tier) == "string" and ALLOWED_TIER[g.tier]
					then g.tier
					else "ungraded"
				byId[g.id] = {
					id = g.id,
					tier = tier,
					towardFull = g.towardFull == true,
					evidence = if type(g.evidence) == "string" then g.evidence else "",
					gap = if type(g.gap) == "string" then g.gap else "",
				}
			end
		end
	end
	local out: { Grade } = {}
	for _, c in ipairs(rubric.criteria) do
		out[#out + 1] = byId[c.id]
			or { id = c.id, tier = "ungraded", towardFull = false, evidence = "", gap = "" }
	end
	local summary = if type(raw) == "table" and type(raw.summary) == "string"
		then raw.summary
		else ""
	return { grades = out, summary = summary }
end

-- Render a fails-first report citing each criterion's concrete_fix (the rubric owns the fix).
function EvaluateReport.renderReport(rubric: Rubric, validated: Validated): string
	local critById: { [string]: RubricCatalog.Criterion } = {}
	for _, c in ipairs(rubric.criteria) do
		critById[c.id] = c
	end
	local counts: { [string]: number } = { pass = 0, partial = 0, fail = 0, ungraded = 0 }
	for _, g in ipairs(validated.grades) do
		counts[g.tier] = (counts[g.tier] or 0) + 1
	end
	local total = #validated.grades
	local lines: { string } = {
		string.format(
			"Evaluation: %s (v%s) — %d/%d pass, %d partial, %d fail%s",
			rubric.module,
			rubric.version,
			counts.pass,
			total,
			counts.partial,
			counts.fail,
			if counts.ungraded > 0 then string.format(", %d ungraded", counts.ungraded) else ""
		),
	}
	if validated.summary ~= "" then
		table.insert(lines, validated.summary)
	end
	-- killer-systems one-liner
	local gradeById: { [string]: Grade } = {}
	for _, g in ipairs(validated.grades) do
		gradeById[g.id] = g
	end
	local killers: { string } = {}
	for _, c in ipairs(rubric.criteria) do
		if string.find(c.statement, "KILLER SYSTEM", 1, true) ~= nil then
			local g = gradeById[c.id]
			table.insert(killers, c.id .. "=" .. TIER_GLYPH[if g then g.tier else "ungraded"])
		end
	end
	if #killers > 0 then
		table.insert(lines, "Killer systems: " .. table.concat(killers, ", "))
	end
	-- fails-first detail
	local order: { Grade } = {}
	for _, g in ipairs(validated.grades) do
		table.insert(order, g)
	end
	table.sort(order, function(a, b)
		return (TIER_RANK[a.tier] or 2) < (TIER_RANK[b.tier] or 2)
	end)
	for _, g in ipairs(order) do
		local c = critById[g.id]
		table.insert(lines, "")
		table.insert(lines, string.format("[%s] %s", TIER_GLYPH[g.tier] or "?", g.id))
		if g.evidence ~= "" then
			table.insert(lines, "  evidence: " .. g.evidence)
		end
		if g.tier ~= "pass" or not g.towardFull then
			if g.gap ~= "" then
				table.insert(lines, "  gap: " .. g.gap)
			end
			if c ~= nil and c.concrete_fix ~= "" then
				table.insert(lines, "  fix: " .. c.concrete_fix)
			end
		end
	end
	return table.concat(lines, "\n")
end

return EvaluateReport
