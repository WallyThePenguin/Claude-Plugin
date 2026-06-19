--!strict
-- PlaceSpec: in-Studio unit test for the PURE offset math of place_relative (anchor-local direction ->
-- world point). Run via temporarily adding `require(script.PlaceSpec).run()` to init.server.luau,
-- build, reopen Studio, read Output. The impure apply (resolve/region/recording) is live-verified.

local Place = require(script.Parent.Tools.Place)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function approxV(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude < 1e-3
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("axis-aligned anchor: each direction maps to the expected world point", function()
		local cf = CFrame.new(0, 0, 0)
		local checks = {
			{ "front", Vector3.new(0, 0, -5) },
			{ "back", Vector3.new(0, 0, 5) },
			{ "right", Vector3.new(5, 0, 0) },
			{ "left", Vector3.new(-5, 0, 0) },
			{ "up", Vector3.new(0, 5, 0) },
			{ "down", Vector3.new(0, -5, 0) },
		}
		for _, c in checks do
			local got = Place.offsetPoint(cf, c[1] :: string, 5)
			if got == nil or not approxV(got, c[2] :: Vector3) then
				return false, (c[1] :: string) .. " got " .. tostring(got)
			end
		end
		return true
	end)

	add("yaw-rotated anchor: 'front' follows the anchor's facing (anchor-local)", function()
		-- Anchor turned +90deg about Y: local -Z (front) now points along world -X.
		local cf = CFrame.Angles(0, math.rad(90), 0)
		local got = Place.offsetPoint(cf, "front", 5)
		return got ~= nil and approxV(got, Vector3.new(-5, 0, 0)), tostring(got)
	end)

	add("translated anchor: offset is relative to the anchor's position", function()
		local cf = CFrame.new(10, 2, 3)
		local got = Place.offsetPoint(cf, "right", 4)
		return got ~= nil and approxV(got, Vector3.new(14, 2, 3)), tostring(got)
	end)

	add("unknown direction returns nil", function()
		return Place.offsetPoint(CFrame.new(), "sideways", 5) == nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total, failed = #cases, 0
	print("=== PlaceSpec: running " .. tostring(total) .. " cases ===")
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
