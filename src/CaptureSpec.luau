--!strict
-- CaptureSpec: in-Studio self-test for the PURE surface of CaptureCore (camera framing math, presets,
-- downscale policy, elevation mapping). Run via temporarily adding `require(script.CaptureSpec).run()`
-- to init.server.luau, build, reopen Studio, read Output. Impure helpers (camera set/restore, trigger,
-- HTTP fetch) are LIVE-verified in Studio, not here.

local CaptureCore = require(script.Parent.Tools.CaptureCore)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function approx(a: number, b: number): boolean
	return math.abs(a - b) < 1e-3
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("yawsFor(4) is 0/90/180/270", function()
		local y = CaptureCore.yawsFor(4)
		if #y ~= 4 then
			return false, "len " .. #y
		end
		return approx(y[1], 0) and approx(y[2], 90) and approx(y[3], 180) and approx(y[4], 270)
	end)

	add("frameCFrame front (yaw0,pitch0) places the eye on +Z looking at center", function()
		local center = Vector3.new(0, 0, 0)
		local cf = CaptureCore.frameCFrame(center, Vector3.new(4, 4, 4), 0, 0, 1, 70)
		if cf.Position.Z <= 0 then
			return false, "eye not on +Z"
		end
		if not (approx(cf.Position.X, 0) and approx(cf.Position.Y, 0)) then
			return false, "eye not on the Z axis"
		end
		if cf.LookVector.Z >= 0 then
			return false, "not looking toward center"
		end
		return true
	end)

	add("frameCFrame distance scales with target size", function()
		local c = Vector3.new(0, 0, 0)
		local near = CaptureCore.frameCFrame(c, Vector3.new(2, 2, 2), 0, 0, 1, 70).Position.Z
		local far = CaptureCore.frameCFrame(c, Vector3.new(20, 20, 20), 0, 0, 1, 70).Position.Z
		return far > near
	end)

	add("frameCFrame distScale multiplies distance", function()
		local c = Vector3.new(0, 0, 0)
		local d1 = CaptureCore.frameCFrame(c, Vector3.new(4, 4, 4), 0, 0, 1, 70).Position.Z
		local d2 = CaptureCore.frameCFrame(c, Vector3.new(4, 4, 4), 0, 0, 2, 70).Position.Z
		return approx(d2, d1 * 2)
	end)

	add("PRESETS has the seven named angles, top/bottom non-degenerate", function()
		for _, n in { "front", "back", "left", "right", "top", "bottom", "iso" } do
			if CaptureCore.PRESETS[n] == nil then
				return false, "missing " .. n
			end
		end
		return math.abs(CaptureCore.PRESETS.top.pitch) < 90
			and math.abs(CaptureCore.PRESETS.bottom.pitch) < 90
	end)

	add("elevationPitch maps low/eye/high and passes numbers through", function()
		return CaptureCore.elevationPitch("low") == 5
			and CaptureCore.elevationPitch("high") == 45
			and CaptureCore.elevationPitch("eye") == 20
			and CaptureCore.elevationPitch(33) == 33
			and CaptureCore.elevationPitch(nil) == 20
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total, failed = #cases, 0
	print("=== CaptureSpec: running " .. tostring(total) .. " cases ===")
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
	print("=== Summary: " .. tostring(total - failed) .. "/" .. tostring(total) .. " passed ===")
	return { passed = failed == 0, total = total, failed = failed }
end

return M
