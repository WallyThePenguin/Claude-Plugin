--!strict
-- BuiltinCorpusSpec: a regression guard for the BUILT-IN quality corpus. Asserts that every expected
-- category's rubric AND build guide actually load (decode + validate at store construction) and resolve —
-- so a future codegen/validation regression that silently drops a category is caught here instead of in
-- production. Asserts PRESENCE of each expected module (not a hard count), so adding an 11th category does
-- not break this, but DROPPING one does. Pure (the stores build their built-ins with no plugin).
-- Run via `& scripts/studio-agent.ps1 luau 'return tostring(require(script.Parent.BuiltinCorpusSpec).run())'`.

local RubricStore = require(script.Parent.RubricStore)
local BuildGuideStore = require(script.Parent.BuildGuideStore)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

-- The categories onboarded via the train-category / train-recipe factories (2026-06: 5 original + 5 batch).
local EXPECTED = {
	"locomotion",
	"vfx",
	"environment",
	"combat",
	"gui",
	"audio",
	"camera",
	"characters",
	"vehicles",
	"npc",
}

local function moduleSet(list: { any }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, item in ipairs(list) do
		if type(item) == "table" and type(item.module) == "string" then
			set[item.module] = true
		end
	end
	return set
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("every expected built-in RUBRIC loads (validates at construction)", function()
		local have = moduleSet(RubricStore.new():all())
		for _, cat in ipairs(EXPECTED) do
			if not have[cat] then
				return false, "missing rubric: " .. cat
			end
		end
		return true
	end)

	add("every expected built-in RUBRIC resolves to non-empty text", function()
		local store = RubricStore.new()
		for _, cat in ipairs(EXPECTED) do
			local text, ok = store:resolve(cat)
			if not ok or type(text) ~= "string" or #text < 50 then
				return false, "rubric did not resolve: " .. cat
			end
		end
		return true
	end)

	add("every expected built-in BUILD GUIDE loads (validates at construction)", function()
		local have = moduleSet(BuildGuideStore.new(nil):all())
		for _, cat in ipairs(EXPECTED) do
			if not have[cat] then
				return false, "missing build guide: " .. cat
			end
		end
		return true
	end)

	add("every expected built-in BUILD GUIDE resolves to non-empty text", function()
		local store = BuildGuideStore.new(nil)
		for _, cat in ipairs(EXPECTED) do
			local text, ok = store:resolve(cat)
			if not ok or type(text) ~= "string" or #text < 50 then
				return false, "build guide did not resolve: " .. cat
			end
		end
		return true
	end)

	add("rubric + guide catalog blocks are non-empty (ride the always-on preamble)", function()
		return #RubricStore.new():catalogBlock() > 0
			and #BuildGuideStore.new(nil):catalogBlock() > 0
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
			print("[BuiltinCorpusSpec] PASS " .. c.name)
		else
			warn("[BuiltinCorpusSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[BuiltinCorpusSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
