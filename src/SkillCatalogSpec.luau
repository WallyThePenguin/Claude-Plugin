--!strict
-- SkillCatalogSpec: in-Studio self-test for the PURE SkillCatalog helpers (no DataModel). Run via
-- temporarily adding `require(script.SkillCatalogSpec).run()` to init.server.luau, build, reopen
-- Studio, read Output.

local SkillCatalog = require(script.Parent.SkillCatalog)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalizeName slugifies and rejects empty", function()
		return SkillCatalog.normalizeName("Shop GUI!") == "shop-gui"
			and SkillCatalog.normalizeName("  --R15 NPC--  ") == "r15-npc"
			and SkillCatalog.normalizeName("") == nil
			and SkillCatalog.normalizeName("!!!") == nil
			and SkillCatalog.normalizeName(5) == nil
	end)

	add("normalizeParams drops malformed, caps count, coerces required", function()
		local raw = {
			{ name = "title", description = "the title", required = true },
			{ name = "  ", description = "blank name" },
			{ name = "count" },
			"nope",
		}
		local p = SkillCatalog.normalizeParams(raw)
		return #p == 2
			and p[1].name == "title"
			and p[1].required == true
			and p[2].name == "count"
			and p[2].required == false
	end)

	add("validateSkill accepts a good skill and normalizes the name", function()
		local s, err = SkillCatalog.validateSkill(
			{ name = "Shop GUI", description = " build a shop ", body = " do it ", parameters = {} },
			"builtin",
			"recipe"
		)
		return err == nil
			and s ~= nil
			and s.name == "shop-gui"
			and s.description == "build a shop"
			and s.body == "do it"
			and s.category == "recipe"
			and s.source == "builtin"
	end)

	add("validateSkill rejects bad name / empty description / empty body", function()
		local _, e1 = SkillCatalog.validateSkill(
			{ name = "!!!", description = "x", body = "y" },
			"user",
			"recipe"
		)
		local _, e2 = SkillCatalog.validateSkill(
			{ name = "ok", description = "  ", body = "y" },
			"user",
			"recipe"
		)
		local _, e3 = SkillCatalog.validateSkill(
			{ name = "ok", description = "x", body = "  " },
			"user",
			"recipe"
		)
		return e1 ~= nil and e2 ~= nil and e3 ~= nil
	end)

	add("renderSkill errors on a missing required param before building", function()
		local skill = (
			SkillCatalog.validateSkill({
				name = "x",
				description = "d",
				body = "build {{title}}",
				parameters = { { name = "title", description = "t", required = true } },
			}, "builtin", "recipe")
		)
		local text, ok = SkillCatalog.renderSkill(skill :: any, {})
		return ok == false and string.find(text, "title", 1, true) ~= nil
	end)

	add(
		"renderSkill substitutes {{param}} (incl. a hyphenated name) and appends args block",
		function()
			local skill = (
				SkillCatalog.validateSkill({
					name = "x",
					description = "d",
					body = "make {{item-name}} now",
					parameters = { { name = "item-name", description = "n", required = false } },
				}, "builtin", "recipe")
			)
			local text, ok = SkillCatalog.renderSkill(skill :: any, { ["item-name"] = "Sword" })
			return ok == true
				and string.find(text, "make Sword now", 1, true) ~= nil
				and string.find(text, "## Provided arguments", 1, true) ~= nil
				and string.find(text, "- item-name: Sword", 1, true) ~= nil
		end
	)

	add("renderSkill leaves an undeclared placeholder literal", function()
		local skill = (
			SkillCatalog.validateSkill(
				{ name = "x", description = "d", body = "{{nope}}" },
				"builtin",
				"recipe"
			)
		)
		local text = SkillCatalog.renderSkill(skill :: any, {})
		return string.find(text, "{{nope}}", 1, true) ~= nil
	end)

	add("findByName matches on the normalized name", function()
		local s = (
			SkillCatalog.validateSkill(
				{ name = "shop-gui", description = "d", body = "b" },
				"builtin",
				"recipe"
			)
		)
		local list = { s :: any }
		return SkillCatalog.findByName(list, "Shop GUI") ~= nil
			and SkillCatalog.findByName(list, "missing") == nil
	end)

	add("catalogBlock groups by family and is empty when no skills", function()
		if SkillCatalog.catalogBlock({}) ~= "" then
			return false, "empty not blank"
		end
		local recipe = (
			SkillCatalog.validateSkill(
				{ name = "leaderstats", description = "stats", body = "b" },
				"builtin",
				"recipe"
			)
		)
		local work = (
			SkillCatalog.validateSkill(
				{ name = "test-first", description = "tdd", body = "b" },
				"builtin",
				"working"
			)
		)
		local mine = (
			SkillCatalog.validateSkill(
				{ name = "my-thing", description = "mine", body = "b" },
				"user",
				"recipe"
			)
		)
		local txt = SkillCatalog.catalogBlock({ recipe :: any, work :: any, mine :: any })
		return string.find(txt, "## Build recipes", 1, true) ~= nil
			and string.find(txt, "## Working skills", 1, true) ~= nil
			and string.find(txt, "## Your skills", 1, true) ~= nil
			and string.find(txt, "- leaderstats — stats", 1, true) ~= nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== SkillCatalogSpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	local passed = total - failed
	print(
		"=== Summary: "
			.. tostring(passed)
			.. "/"
			.. tostring(total)
			.. " passed, "
			.. tostring(failed)
			.. " failed ==="
	)
	return { passed = failed == 0, total = total, failed = failed }
end

return M
