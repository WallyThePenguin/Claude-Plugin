--!strict
-- CameraRigSpec: in-Studio self-test for the PURE CameraRig helpers (no DataModel). Run via
-- temporarily adding `require(script.CameraRigSpec).run()` to init.server.luau, build, reopen Studio,
-- read Output. Mirrors SkillCatalogSpec.

local CameraRig = require(script.Parent.CameraRig)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function approx(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("wrapAzimuth wraps into [0,360)", function()
		return approx(CameraRig.wrapAzimuth(370), 10)
			and approx(CameraRig.wrapAzimuth(-30), 330)
			and approx(CameraRig.wrapAzimuth(360), 0)
			and approx(CameraRig.wrapAzimuth(45), 45)
	end)

	add("clampElevation clamps to [-89,89]", function()
		return approx(CameraRig.clampElevation(95), 89)
			and approx(CameraRig.clampElevation(-120), -89)
			and approx(CameraRig.clampElevation(45), 45)
	end)

	add("clampZoom clamps to [0.2,8]", function()
		return approx(CameraRig.clampZoom(0), 0.2)
			and approx(CameraRig.clampZoom(99), 8)
			and approx(CameraRig.clampZoom(1), 1)
	end)

	add("applyMove relative adds deltas + clamps/wraps", function()
		local s = { azimuth = 35, elevation = 20, distScale = 1 }
		local a = CameraRig.applyMove(s, { azimuth = 30 })
		local b = CameraRig.applyMove(s, { elevation = 80 }) -- 100 -> 89
		local c = CameraRig.applyMove(s, { zoom = 10 }) -- 11 -> 8
		return approx(a.azimuth, 65)
			and approx(a.elevation, 20)
			and approx(b.elevation, 89)
			and approx(c.distScale, 8)
	end)

	add("applyMove absolute sets values; missing fields unchanged", function()
		local s = { azimuth = 35, elevation = 20, distScale = 1 }
		local abs = CameraRig.applyMove(s, { elevation = 89, azimuth = 400, relative = false })
		local none = CameraRig.applyMove(s, {})
		return approx(abs.elevation, 89)
			and approx(abs.azimuth, 40) -- 400 wraps to 40
			and approx(abs.distScale, 1)
			and approx(none.azimuth, 35)
			and approx(none.elevation, 20)
			and approx(none.distScale, 1)
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
			print("[CameraRigSpec] PASS " .. c.name)
		else
			warn("[CameraRigSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[CameraRigSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
