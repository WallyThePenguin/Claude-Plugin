--!strict
-- LearningsSpec: in-Studio self-test for the PURE Learnings logic (no DataModel). Run via temporarily adding
-- `require(script.LearningsSpec).run()` to init.server.luau.

local Learnings = require(script.Parent.Learnings)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalizeCategory lowercases/trims and rejects empty", function()
		if Learnings.normalizeCategory("  Locomotion ") ~= "locomotion" then
			return false, "lower/trim failed"
		end
		if Learnings.normalizeCategory("") ~= nil or Learnings.normalizeCategory(5) ~= nil then
			return false, "empty/non-string not rejected"
		end
		return true
	end)

	add("addTo appends with incrementing id and FIFO-caps at MAX_PER_CATEGORY", function()
		local entries: { Learnings.Entry } = {}
		for i = 1, Learnings.MAX_PER_CATEGORY + 3 do
			entries = (Learnings.addTo(entries, "lesson " .. i, 100 + i))
		end
		if #entries ~= Learnings.MAX_PER_CATEGORY then
			return false, "cap failed: " .. tostring(#entries)
		end
		-- oldest dropped: first remaining is "lesson 4" (1..3 dropped), id continues upward
		if entries[1].text ~= "lesson 4" then
			return false, "FIFO drop wrong: " .. entries[1].text
		end
		if entries[#entries].id ~= Learnings.MAX_PER_CATEGORY + 3 then
			return false, "id scheme wrong: " .. tostring(entries[#entries].id)
		end
		return true
	end)

	add("addTo rejects empty text (entries unchanged)", function()
		local entries: { Learnings.Entry } = { { id = 1, text = "x", createdAt = 0 } }
		local out, note = Learnings.addTo(entries, "   ", 1)
		if #out ~= 1 or string.find(note, "non-empty", 1, true) == nil then
			return false, "empty text not rejected"
		end
		return true
	end)

	add("forgetFrom removes the matching id", function()
		local entries: { Learnings.Entry } =
			{ { id = 1, text = "a", createdAt = 0 }, { id = 2, text = "b", createdAt = 0 } }
		local out, removed = Learnings.forgetFrom(entries, 1)
		if not removed or #out ~= 1 or out[1].id ~= 2 then
			return false, "forget wrong"
		end
		return true
	end)

	add("normalizeEntry rejects a corrupt id", function()
		if Learnings.normalizeEntry({ id = -1, text = "x" }) ~= nil then
			return false, "negative id accepted"
		end
		if Learnings.normalizeEntry({ id = 1.5, text = "x" }) ~= nil then
			return false, "float id accepted"
		end
		if Learnings.normalizeEntry({ id = 2, text = "ok" }) == nil then
			return false, "valid entry rejected"
		end
		return true
	end)

	add("normalizeIndex de-dups + normalizes category names", function()
		local idx = Learnings.normalizeIndex({ "Locomotion", "locomotion", "  vfx ", "" })
		if #idx ~= 2 or idx[1] ~= "locomotion" or idx[2] ~= "vfx" then
			return false, "index normalize wrong: " .. table.concat(idx, ",")
		end
		return true
	end)

	add("renderCategory formats #id lines / (none)", function()
		if Learnings.renderCategory({}) ~= "(none)" then
			return false, "(none) wrong"
		end
		local r = Learnings.renderCategory({ { id = 3, text = "foo", createdAt = 0 } })
		if r ~= "#3 foo" then
			return false, "render wrong: " .. r
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
			print("[LearningsSpec] PASS " .. c.name)
		else
			warn("[LearningsSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[LearningsSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
