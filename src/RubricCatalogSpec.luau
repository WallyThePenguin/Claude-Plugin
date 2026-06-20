--!strict
-- RubricCatalogSpec: in-Studio self-test for the PURE RubricCatalog helpers (no DataModel). Run via
-- temporarily adding `require(script.RubricCatalogSpec).run()` to init.server.luau, build, reopen
-- Studio, read Output. Mirrors SkillCatalogSpec.

local RubricCatalog = require(script.Parent.RubricCatalog)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function goodRaw(): any
	return {
		module = "Locomotion",
		version = "1.1",
		criteria = {
			{
				id = "c-good",
				order_index = 2,
				tier = "good",
				statement = "Warps by speed AND direction.",
				above_generic_rationale = "Default plays one loop.",
				grading = { pass = "blend tree", partial = "speed only", fail = "single loop" },
				evidence_required = "strafe shows side motion",
				concrete_fix = "add a 2D blend space",
				exemplar_refs = { "https://example.com/x" },
			},
			{
				id = "c-base",
				order_index = 1,
				tier = "baseline",
				statement = "Idle/walk/run exist.",
				grading = { pass = "p", partial = "pa", fail = "f" },
			},
		},
	}
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("validateRubric accepts a good rubric, lowercases module, sorts by order_index", function()
		local r, err = RubricCatalog.validateRubric(goodRaw())
		return err == nil
			and r ~= nil
			and r.module == "locomotion"
			and r.system_module == "locomotion"
			and #r.criteria == 2
			and r.criteria[1].id == "c-base" -- order_index 1 first
			and r.criteria[2].id == "c-good"
	end)

	add("validateRubric rejects bad inputs", function()
		local _, e1 = RubricCatalog.validateRubric("nope")
		local _, e2 = RubricCatalog.validateRubric({ module = "x", criteria = {} })
		local bad = goodRaw()
		bad.criteria[1].tier = "amazing"
		local _, e3 = RubricCatalog.validateRubric(bad)
		local bad2 = goodRaw()
		bad2.criteria[1].grading = { pass = "p" } -- missing partial/fail
		local _, e4 = RubricCatalog.validateRubric(bad2)
		return e1 ~= nil and e2 ~= nil and e3 ~= nil and e4 ~= nil
	end)

	add("render contains tiered headers + a concrete_fix + the version", function()
		local r = (RubricCatalog.validateRubric(goodRaw()))
		assert(r ~= nil, "validateRubric returned nil for a good rubric")
		local text = RubricCatalog.render(r :: any)
		return string.find(text, "v1.1", 1, true) ~= nil
			and string.find(text, "## Baseline", 1, true) ~= nil
			and string.find(text, "## Good", 1, true) ~= nil
			and string.find(text, "add a 2D blend space", 1, true) ~= nil
	end)

	add("catalogBlock lists a line per rubric with counts; empty -> ''", function()
		local r = (RubricCatalog.validateRubric(goodRaw()))
		assert(r ~= nil, "validateRubric returned nil for a good rubric")
		local block = RubricCatalog.catalogBlock({ r :: any })
		return RubricCatalog.catalogBlock({}) == ""
			and string.find(block, "locomotion", 1, true) ~= nil
			and string.find(block, "2 criteria", 1, true) ~= nil
			and string.find(block, "1 baseline", 1, true) ~= nil
	end)

	add("findByCategory matches case-insensitively; miss + bad input -> nil", function()
		local r = (RubricCatalog.validateRubric(goodRaw()))
		assert(r ~= nil, "validateRubric returned nil for a good rubric")
		local list = { r :: any }
		return RubricCatalog.findByCategory(list, "LOCOMOTION") ~= nil
			and RubricCatalog.findByCategory(list, "map") == nil
			and RubricCatalog.findByCategory(list, 5) == nil
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
			print("[RubricCatalogSpec] PASS " .. c.name)
		else
			warn("[RubricCatalogSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[RubricCatalogSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
