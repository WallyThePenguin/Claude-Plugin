--!strict
-- Movement: plausibility checks over a stream of position samples.
--
-- READ THIS BEFORE USING IT. Roblox replicates character physics FROM the client by
-- design. Trying to make movement server-authoritative fights the engine and produces
-- rubber-banding that feels worse than the cheating does. So this module does not
-- authoritate anything - it produces EVIDENCE, which you feed to AbuseScore and act on
-- in aggregate.
--
-- It also works on plain numbers and 3-component tables rather than Vector3, so it runs
-- under Lune. Pass `{x, y, z}` or anything with .X/.Y/.Z.

export type Sample = { X: number, Y: number, Z: number }

export type Options = {
	-- Highest speed the game can legitimately produce, studs/second. Set it from the
	-- actual maximum: base walkspeed, plus every sprint, dash and knockback effect.
	maxSpeed: number,
	-- Tolerance multiplier on maxSpeed, absorbing replication jitter. 1.5 is a
	-- reasonable start; tune it against real logs, not intuition.
	tolerance: number?,
	-- Distance in one sample that no legitimate movement can produce.
	maxStep: number?,
	-- Plausible vertical band for the map. Outside it means fell-through-the-world or
	-- flying.
	minY: number?,
	maxY: number?,
	-- Samples closer together than this are ignored: over a tiny interval, a stud of
	-- jitter reads as an enormous speed. This is the single biggest source of false
	-- positives in naive implementations.
	minInterval: number?,
}

export type Violation = {
	kind: "speed" | "step" | "bounds" | "nan",
	detail: string,
	-- Suggested AbuseScore weight. Confident signals score higher: a NaN position is
	-- unambiguous, a marginal speed sample is not.
	weight: number,
}

local Movement = {}

local function component(sample: Sample, axis: "X" | "Y" | "Z"): number
	return sample[axis]
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function distance(a: Sample, b: Sample): number
	local dx = component(a, "X") - component(b, "X")
	local dy = component(a, "Y") - component(b, "Y")
	local dz = component(a, "Z") - component(b, "Z")
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--[[
	Check one step. `previous`/`current` are positions; `elapsed` is the seconds between
	them. Returns a list of violations, empty when the step is plausible.

	Nothing is remembered between calls - the caller owns the previous sample. That keeps
	this pure and lets the caller decide the sampling cadence.
]]
function Movement.check(
	previous: Sample,
	current: Sample,
	elapsed: number,
	options: Options
): { Violation }
	local violations: { Violation } = {}
	local tolerance = options.tolerance or 1.5
	local minInterval = options.minInterval or 0.1

	-- A non-finite component poisons every comparison below, so bail immediately. This
	-- is unambiguous and worth a heavy weight: no legitimate client reports NaN.
	for _, axis in { "X", "Y", "Z" } :: { "X" | "Y" | "Z" } do
		if not isFinite(component(current, axis)) then
			table.insert(violations, {
				kind = "nan" :: "nan",
				detail = `{axis} is not finite`,
				weight = 5,
			})
			return violations
		end
	end

	if options.minY ~= nil and component(current, "Y") < options.minY then
		table.insert(violations, {
			kind = "bounds" :: "bounds",
			detail = `Y {component(current, "Y")} below {options.minY}`,
			weight = 2,
		})
	end
	if options.maxY ~= nil and component(current, "Y") > options.maxY then
		table.insert(violations, {
			kind = "bounds" :: "bounds",
			detail = `Y {component(current, "Y")} above {options.maxY}`,
			weight = 2,
		})
	end

	local moved = distance(previous, current)

	local maxStep = options.maxStep
	if maxStep ~= nil and moved > maxStep then
		table.insert(violations, {
			kind = "step" :: "step",
			detail = `moved {string.format("%.1f", moved)} studs in one sample (max {maxStep})`,
			weight = 3,
		})
	end

	-- Only now consider speed, and only over a long enough interval to be meaningful.
	if elapsed >= minInterval then
		local speed = moved / elapsed
		local limit = options.maxSpeed * tolerance
		if speed > limit then
			table.insert(violations, {
				kind = "speed" :: "speed",
				detail = `{string.format("%.1f", speed)} studs/s over {string.format(
					"%.2f",
					elapsed
				)}s (limit {string.format("%.1f", limit)})`,
				-- Scale with how far past the limit it is: marginally fast is weak
				-- evidence, 5x is strong.
				weight = math.clamp(speed / limit, 1, 4),
			})
		end
	end

	return violations
end

--[[
	Convenience: is this position inside the arena's horizontal footprint?

	Not a cheat check on its own - a player can be legitimately outside during a
	transition - but combined with "the round is running" it is a strong signal.
]]
function Movement.withinRadius(sample: Sample, centre: Sample, radius: number): boolean
	local dx = component(sample, "X") - component(centre, "X")
	local dz = component(sample, "Z") - component(centre, "Z")
	return (dx * dx + dz * dz) <= radius * radius
end

return Movement
