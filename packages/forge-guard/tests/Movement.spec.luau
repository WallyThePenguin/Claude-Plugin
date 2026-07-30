--!strict
-- Specs for Movement.

local Movement = require("../src/Movement")

local function at(x: number, y: number, z: number)
	return { X = x, Y = y, Z = z }
end

local function kinds(violations)
	local out = {}
	for _, violation in violations do
		table.insert(out, violation.kind)
	end
	table.sort(out)
	return out
end

local OPTIONS = { maxSpeed = 20, tolerance = 1.5, maxStep = 50, minY = -20, maxY = 200 }

return function(t)
	t.test("plausible movement produces no violations", function(expect)
		local violations = Movement.check(at(0, 5, 0), at(2, 5, 0), 0.2, OPTIONS)
		expect(#violations).toBe(0)
	end)

	t.test("flags speed past the tolerated limit", function(expect)
		-- 30 studs in 0.2s == 150 studs/s, well past 20 * 1.5.
		local violations = Movement.check(at(0, 5, 0), at(30, 5, 0), 0.2, OPTIONS)
		expect(kinds(violations)).toContain("speed")
	end)

	t.test("tolerance absorbs jitter just over the nominal speed", function(expect)
		-- 25 studs/s: over maxSpeed 20, under the 30 limit after tolerance.
		local violations = Movement.check(at(0, 5, 0), at(5, 5, 0), 0.2, OPTIONS)
		expect(#violations).toBe(0)
	end)

	-- The single biggest source of false positives in naive implementations: over a 10ms
	-- interval, one stud of replication jitter reads as 100 studs/second.
	t.test("ignores speed over an interval too short to be meaningful", function(expect)
		local violations = Movement.check(at(0, 5, 0), at(1, 5, 0), 0.001, OPTIONS)
		expect(#violations).toBe(0)
	end)

	t.test("still flags an impossible single step even over a tiny interval", function(expect)
		-- maxStep is interval-independent, which is what catches a teleport that
		-- arrives inside one tick.
		local violations = Movement.check(at(0, 5, 0), at(500, 5, 0), 0.001, OPTIONS)
		expect(kinds(violations)).toContain("step")
	end)

	t.test("flags positions outside the vertical band", function(expect)
		expect(kinds(Movement.check(at(0, 5, 0), at(0, -100, 0), 1, OPTIONS))).toContain("bounds")
		expect(kinds(Movement.check(at(0, 5, 0), at(0, 5000, 0), 1, OPTIONS))).toContain("bounds")
	end)

	-- A non-finite component makes every comparison below it meaningless, so it short-
	-- circuits. No legitimate client reports NaN, hence the heavy weight.
	t.test("short-circuits on a non-finite component with high confidence", function(expect)
		local violations = Movement.check(at(0, 5, 0), at(0 / 0, 5, 0), 1, OPTIONS)
		expect(#violations).toBe(1)
		expect(violations[1].kind).toBe("nan")
		expect(violations[1].weight).toBe(5)
		expect(kinds(Movement.check(at(0, 5, 0), at(0, math.huge, 0), 1, OPTIONS))).toContain("nan")
	end)

	t.test("speed weight scales with how far past the limit it is", function(expect)
		local marginal = Movement.check(at(0, 5, 0), at(7, 5, 0), 0.2, OPTIONS)
		local egregious = Movement.check(at(0, 5, 0), at(40, 5, 0), 0.2, OPTIONS)
		expect(marginal[1].weight < egregious[1].weight).toBe(true)
		-- Capped, so one absurd sample cannot single-handedly trip a threshold.
		expect(egregious[1].weight).toBe(4)
	end)

	t.test("reports several independent violations at once", function(expect)
		local violations = Movement.check(at(0, 5, 0), at(400, 900, 0), 0.5, OPTIONS)
		expect(kinds(violations)).toEqual({ "bounds", "speed", "step" })
	end)

	t.test("withinRadius ignores height", function(expect)
		local centre = at(0, 0, 0)
		expect(Movement.withinRadius(at(10, 999, 10), centre, 20)).toBe(true)
		expect(Movement.withinRadius(at(30, 0, 30), centre, 20)).toBe(false)
		-- Exactly on the boundary counts as inside.
		expect(Movement.withinRadius(at(20, 0, 0), centre, 20)).toBe(true)
	end)
end
