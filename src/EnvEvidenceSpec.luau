--!strict
-- EnvEvidenceSpec: in-Studio self-test for the PURE EnvEvidence helpers (no DataModel). Run via temporarily
-- adding `require(script.EnvEvidenceSpec).run()` to init.server.luau.

local EnvEvidence = require(script.Parent.EnvEvidence)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("isDefaultMaterial: Plastic/SmoothPlastic/empty default, others crafted", function()
		return EnvEvidence.isDefaultMaterial("Plastic") == true
			and EnvEvidence.isDefaultMaterial("SmoothPlastic") == true
			and EnvEvidence.isDefaultMaterial("") == true
			and EnvEvidence.isDefaultMaterial("Concrete") == false
			and EnvEvidence.isDefaultMaterial("Neon") == false
	end)

	add("summarize formats the stats", function()
		local s: EnvEvidence.Stats = {
			meshes = 4,
			models = 2,
			totalParts = 10,
			craftedMat = 7,
			surfaceAppearance = 1,
			lights = 3,
			atmosphere = true,
			postEffects = 2,
		}
		local out = EnvEvidence.summarize(s)
		if string.find(out, "10 BaseParts (4 MeshParts, 2 Models)", 1, true) == nil then
			return false, "parts: " .. out
		end
		if string.find(out, "7/10 parts use a crafted", 1, true) == nil then
			return false, "crafted: " .. out
		end
		if string.find(out, "3 placed lights", 1, true) == nil then
			return false, "lights: " .. out
		end
		if string.find(out, "Atmosphere=yes, 2 post-effects", 1, true) == nil then
			return false, "lighting: " .. out
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
			print("[EnvEvidenceSpec] PASS " .. c.name)
		else
			warn("[EnvEvidenceSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[EnvEvidenceSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
