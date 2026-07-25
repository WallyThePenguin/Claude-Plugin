--!strict
-- BuildGuideCatalogSpec: in-Studio self-test for the PURE BuildGuideCatalog helpers (no DataModel).
-- Run via `& scripts/studio-agent.ps1 luau 'return require(script.Parent.BuildGuideCatalogSpec).run()'`.
-- Mirrors RubricCatalogSpec.

local BuildGuideCatalog = require(script.Parent.BuildGuideCatalog)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function goodRaw(): any
	return {
		module = "Locomotion",
		version = "1.0",
		rubric_version = "1.0",
		overview = "Build a velocity-driven blend system.",
		killer_systems = {
			{ name = "blend tree", what = "speed/dir warp", how = "2D blend space" },
		},
		common_pitfalls = { "single forward loop" },
		tiers = {
			{
				tier = "good",
				goal = "above the mean",
				steps = {
					{
						id = "loco-blend",
						order_index = 2,
						instruction = "Author a 2D blend space across speed and direction.",
						addresses_criteria = { "loco-blend-tree" },
						tools = { "add_keyframe", "bind_animation" },
						pitfalls = "don't key one loop",
					},
				},
			},
			{
				tier = "baseline",
				goal = "it moves",
				steps = {
					{
						id = "loco-loops",
						order_index = 1,
						instruction = "Make idle/walk/run loops.",
					},
				},
			},
		},
		provenance = { coverage = { criteria_total = 2, criteria_addressed = 2, uncovered = {} } },
	}
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("validateGuide accepts a good guide, lowercases module, sorts tiers + steps", function()
		local g, err = BuildGuideCatalog.validateGuide(goodRaw())
		return err == nil
			and g ~= nil
			and g.module == "locomotion"
			and g.system_module == "locomotion"
			and #g.tiers == 2
			and g.tiers[1].tier == "baseline" -- tier order, not input order
			and g.tiers[2].tier == "good"
			and g.tiers[2].steps[1].id == "loco-blend"
	end)

	add("validateGuide rejects bad inputs", function()
		local _, e1 = BuildGuideCatalog.validateGuide("nope")
		local _, e2 = BuildGuideCatalog.validateGuide({ module = "x", tiers = {} })
		local bad = goodRaw()
		bad.tiers[1].tier = "amazing"
		local _, e3 = BuildGuideCatalog.validateGuide(bad)
		local bad2 = goodRaw()
		bad2.tiers[2].steps[1].id = nil -- step missing id
		local _, e4 = BuildGuideCatalog.validateGuide(bad2)
		return e1 ~= nil and e2 ~= nil and e3 ~= nil and e4 ~= nil
	end)

	add("render contains tiered headers + an instruction + tool tags + the version", function()
		local g = (BuildGuideCatalog.validateGuide(goodRaw()))
		assert(g ~= nil, "validateGuide returned nil for a good guide")
		local text = BuildGuideCatalog.render(g :: any)
		return string.find(text, "v1.0", 1, true) ~= nil
			and string.find(text, "## Baseline", 1, true) ~= nil
			and string.find(text, "## Good", 1, true) ~= nil
			and string.find(text, "2D blend space", 1, true) ~= nil
			and string.find(text, "add_keyframe", 1, true) ~= nil
			and string.find(text, "loco-blend-tree", 1, true) ~= nil
	end)

	add("catalogBlock lists a line per guide with counts + coverage; empty -> ''", function()
		local g = (BuildGuideCatalog.validateGuide(goodRaw()))
		assert(g ~= nil, "validateGuide returned nil for a good guide")
		local block = BuildGuideCatalog.catalogBlock({ g :: any })
		return BuildGuideCatalog.catalogBlock({}) == ""
			and string.find(block, "locomotion", 1, true) ~= nil
			and string.find(block, "2 steps", 1, true) ~= nil
			and string.find(block, "2/2", 1, true) ~= nil
	end)

	add("findByCategory matches case-insensitively; miss + bad input -> nil", function()
		local g = (BuildGuideCatalog.validateGuide(goodRaw()))
		assert(g ~= nil, "validateGuide returned nil for a good guide")
		local list = { g :: any }
		return BuildGuideCatalog.findByCategory(list, "LOCOMOTION") ~= nil
			and BuildGuideCatalog.findByCategory(list, "map") == nil
			and BuildGuideCatalog.findByCategory(list, 5) == nil
	end)

	-- ---- user-save pure helpers (saveInto / deleteFrom) ----
	local function guideWithModule(mod: string): any
		local raw = goodRaw()
		raw.module = mod
		local g = BuildGuideCatalog.validateGuide(raw)
		assert(g ~= nil, "validateGuide nil for " .. mod)
		return g
	end

	add("saveInto inserts a new user guide", function()
		local g = guideWithModule("myguide")
		local out, note, ok = BuildGuideCatalog.saveInto({}, g, {})
		return ok
			and #out == 1
			and out[1].module == "myguide"
			and string.find(note, "saved", 1, true) ~= nil
	end)

	add("saveInto rejects a reserved (built-in) module", function()
		local g = guideWithModule("locomotion")
		local out, note, ok = BuildGuideCatalog.saveInto({}, g, { locomotion = true })
		return not ok and #out == 0 and string.find(note, "built-in", 1, true) ~= nil
	end)

	add("saveInto replaces a same-module user guide in place (no duplicate)", function()
		local first = guideWithModule("dup")
		local list = (BuildGuideCatalog.saveInto({}, first, {}))
		local second = guideWithModule("dup")
		second.overview = "v2"
		local out, note, ok = BuildGuideCatalog.saveInto(list, second, {})
		return ok
			and #out == 1
			and out[1].overview == "v2"
			and string.find(note, "updated", 1, true) ~= nil
	end)

	add("saveInto FIFO-drops oldest past MAX_USER_GUIDES", function()
		local list: { any } = {}
		for i = 1, BuildGuideCatalog.MAX_USER_GUIDES do
			list = (BuildGuideCatalog.saveInto(list, guideWithModule("g" .. i), {}))
		end
		local out, note, ok = BuildGuideCatalog.saveInto(list, guideWithModule("overflow"), {})
		return ok
			and #out == BuildGuideCatalog.MAX_USER_GUIDES
			and out[1].module == "g2" -- g1 dropped
			and out[#out].module == "overflow"
			and string.find(note, "dropped", 1, true) ~= nil
	end)

	add("deleteFrom removes an existing user guide", function()
		local list = (BuildGuideCatalog.saveInto({}, guideWithModule("gone"), {}))
		local out, note, ok = BuildGuideCatalog.deleteFrom(list, "GONE")
		return ok and #out == 0 and string.find(note, "deleted", 1, true) ~= nil
	end)

	add("deleteFrom on a missing module -> ok=false, list unchanged", function()
		local list = (BuildGuideCatalog.saveInto({}, guideWithModule("keep"), {}))
		local out, _, ok = BuildGuideCatalog.deleteFrom(list, "nope")
		return (not ok) and #out == 1 and out[1].module == "keep"
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
			print("[BuildGuideCatalogSpec] PASS " .. c.name)
		else
			warn("[BuildGuideCatalogSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[BuildGuideCatalogSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
