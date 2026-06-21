--!strict
-- EvaluateReportSpec: in-Studio self-test for the PURE EvaluateReport logic. Run via temporarily adding
-- `require(script.EvaluateReportSpec).run()` to init.server.luau.

local EvaluateReport = require(script.Parent.EvaluateReport)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

-- A tiny synthetic rubric (2 criteria; one is a KILLER SYSTEM) for the pure tests.
local RUBRIC = {
	module = "test",
	version = "1",
	system_module = "test",
	criteria = {
		{
			id = "c-base",
			order_index = 1,
			tier = "baseline",
			statement = "A baseline thing.",
			above_generic_rationale = "",
			grading = { pass = "p", partial = "pa", fail = "f" },
			evidence_required = "",
			concrete_fix = "do the base fix",
			exemplar_refs = {},
		},
		{
			id = "c-killer",
			order_index = 2,
			tier = "good",
			statement = "KILLER SYSTEM — a big one.",
			above_generic_rationale = "",
			grading = { pass = "p", partial = "pa", fail = "f" },
			evidence_required = "",
			concrete_fix = "do the killer fix",
			exemplar_refs = {},
		},
	},
}

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("buildGradeTool exposes the criterion ids as the id enum", function()
		local tool = EvaluateReport.buildGradeTool(RUBRIC :: any)
		if tool.name ~= "submit_grade" then
			return false, "wrong tool name"
		end
		local idEnum = tool.input_schema.properties.grades.items.properties.id.enum
		if type(idEnum) ~= "table" or idEnum[1] ~= "c-base" or idEnum[2] ~= "c-killer" then
			return false, "id enum missing the criterion ids"
		end
		return true
	end)

	add("validateGrades fills missing criteria as ungraded and clamps bad tiers", function()
		local raw =
			{ grades = { { id = "c-base", tier = "bogus", evidence = "e" } }, summary = "s" }
		local v = EvaluateReport.validateGrades(raw, RUBRIC :: any)
		if #v.grades ~= 2 then
			return false, "expected 2 grades, got " .. tostring(#v.grades)
		end
		if v.grades[1].id ~= "c-base" or v.grades[1].tier ~= "ungraded" then
			return false, "bad tier not clamped to ungraded"
		end
		if v.grades[2].id ~= "c-killer" or v.grades[2].tier ~= "ungraded" then
			return false, "missing criterion not filled as ungraded"
		end
		if v.summary ~= "s" then
			return false, "summary lost"
		end
		return true
	end)

	add("renderReport shows counts, killer status, fails-first, and the concrete fix", function()
		local raw = {
			grades = {
				{ id = "c-base", tier = "pass", towardFull = true, evidence = "ok", gap = "" },
				{
					id = "c-killer",
					tier = "fail",
					towardFull = false,
					evidence = "absent",
					gap = "missing X",
				},
			},
			summary = "overall",
		}
		local v = EvaluateReport.validateGrades(raw, RUBRIC :: any)
		local text = EvaluateReport.renderReport(RUBRIC :: any, v)
		if string.find(text, "1/2 pass, 0 partial, 1 fail", 1, true) == nil then
			return false, "counts line wrong: " .. text
		end
		if string.find(text, "Killer systems: c-killer=FAIL", 1, true) == nil then
			return false, "killer status missing"
		end
		-- the FAIL must appear before the PASS (fails-first)
		local failPos = string.find(text, "%[FAIL%] c%-killer")
		local passPos = string.find(text, "%[PASS%] c%-base")
		if failPos == nil or passPos == nil or failPos >= passPos then
			return false, "not fails-first"
		end
		if string.find(text, "do the killer fix", 1, true) == nil then
			return false, "concrete fix not shown for the fail"
		end
		return true
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[EvaluateReportSpec] PASS " .. c.name)
		else
			warn("[EvaluateReportSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[EvaluateReportSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
