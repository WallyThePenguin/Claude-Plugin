--!strict
-- GuiEvidenceSpec: in-Studio self-test for the PURE GuiEvidence helpers (no DataModel). Run via temporarily
-- adding `require(script.GuiEvidenceSpec).run()` to init.server.luau.

local GuiEvidence = require(script.Parent.GuiEvidence)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("usesScale: nonzero scale on either axis is responsive", function()
		return GuiEvidence.usesScale(0, 0) == false
			and GuiEvidence.usesScale(0.5, 0) == true
			and GuiEvidence.usesScale(0, 1) == true
	end)

	add("summarizeLayout empty -> ''", function()
		return GuiEvidence.summarizeLayout({}) == ""
	end)

	add("summarizeLayout counts facts and formats", function()
		local facts: { GuiEvidence.Fact } = {
			{
				scaleSize = true,
				scalePos = false,
				anchor = true,
				layout = true,
				corner = true,
				padding = false,
				constraint = false,
			},
			{
				scaleSize = false,
				scalePos = false,
				anchor = false,
				layout = false,
				corner = false,
				padding = true,
				constraint = true,
			},
		}
		local s = GuiEvidence.summarizeLayout(facts)
		if string.find(s, "of 2 elements sampled", 1, true) == nil then
			return false, "count: " .. s
		end
		if string.find(s, "1 use scale-based Size", 1, true) == nil then
			return false, "scaleSize: " .. s
		end
		if string.find(s, "1 have UICorner", 1, true) == nil then
			return false, "corner: " .. s
		end
		if string.find(s, "1 have UIPadding", 1, true) == nil then
			return false, "padding: " .. s
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
			print("[GuiEvidenceSpec] PASS " .. c.name)
		else
			warn("[GuiEvidenceSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[GuiEvidenceSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
