--!strict
-- Specs for Claim.
--
-- Uses the REAL History by relative file path, not a stub: the interaction between the
-- rewind window and the policy edge is the thing most worth testing, and a stub would let
-- me assert against my own assumptions instead of the actual buffer.

local Claim = require("../src/Claim")
local History = require("../src/History")

local function at(x: number, y: number, z: number)
	return { X = x, Y = y, Z = z }
end

local SWORD = { range = 10, cooldown = 0.5 }

-- A world where the target walks along +X, one sample every 50ms from t=0 to t=1.
local function walkingTarget()
	local history = History.new({ windowSeconds = 0.25, sampleRate = 20 })
	for step = 0, 20 do
		local time = step * 0.05
		history:Record("target", at(step * 2, 5, 0), time)
		history:Record("attacker", at(0, 5, 0), time)
	end
	return history
end

local function context(history, overrides)
	local base = {
		now = 1.0,
		history = history,
		lastAcceptedAt = nil,
		targetAlive = true,
		weaponEquipped = true,
		sameTeam = false,
		lineOfSight = nil,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base
end

local function claim(overrides)
	local base = {
		attackerId = "attacker",
		targetId = "target",
		at = 0.9,
		origin = at(0, 5, 0),
		weapon = SWORD,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base
end

return function(t)
	-- The whole point: at t=0.9 the target was 36 studs out and unreachable, but at t=0.8
	-- they were 32... so pick a genuinely in-range instant to prove the rewind works.
	t.test("accepts a hit that was in range at the claimed instant", function(expect)
		local history = History.new({ windowSeconds = 0.25, sampleRate = 20 })
		-- Target closes from 30 studs to 4 studs over the window.
		history:Record("target", at(30, 5, 0), 0.8)
		history:Record("target", at(4, 5, 0), 1.0)
		history:Record("attacker", at(0, 5, 0), 0.8)
		history:Record("attacker", at(0, 5, 0), 1.0)

		local verdict = Claim.resolve(claim({ at = 1.0 }), context(history))
		expect(verdict.accepted).toBe(true)
		expect(verdict.reason).toBe("accepted")
		expect(verdict.distance).toBeCloseTo(4)
		expect(verdict.rewoundTo.X).toBeCloseTo(4)
	end)

	-- Rewinding must be able to say NO as well as yes, or it is just trusting the client
	-- with extra steps.
	t.test("rejects a hit that was out of range at the claimed instant", function(expect)
		local history = walkingTarget()
		-- At t=0.9 the target is at X=36, well past the sword's 10 + 4 slack.
		local verdict = Claim.resolve(claim({ at = 0.9 }), context(history))
		expect(verdict.accepted).toBe(false)
		expect(verdict.reason).toBe("out-of-range")
		expect(verdict.distance).toBeCloseTo(36)
	end)

	t.test("slack absorbs interpolation error and hitbox size", function(expect)
		local history = History.new({ windowSeconds = 0.5 })
		history:Record("target", at(13, 5, 0), 1.0)
		history:Record("attacker", at(0, 5, 0), 1.0)
		-- 13 studs: past the 10 range, inside the default 4 slack.
		expect(Claim.resolve(claim({ at = 1.0 }), context(history)).accepted).toBe(true)
		-- Tighten the slack and the same claim fails.
		local strict = table.clone(Claim.DEFAULT_POLICY)
		strict.rangeSlackStuds = 1
		expect(Claim.resolve(claim({ at = 1.0 }), context(history), strict).accepted).toBe(false)
	end)

	-- The most common exploit there is, and a pure comparison against the server's record.
	t.test("rejects an attack inside the cooldown", function(expect)
		local history = walkingTarget()
		local verdict =
			Claim.resolve(claim({ at = 1.0 }), context(history, { lastAcceptedAt = 0.8 }))
		expect(verdict.reason).toBe("cooldown")
		-- Past the cooldown it is judged on its merits again.
		local later = Claim.resolve(claim({ at = 1.0 }), context(history, { lastAcceptedAt = 0.4 }))
		expect(later.reason ~= "cooldown").toBe(true)
	end)

	t.test("cooldown is checked before anything the client said", function(expect)
		local history = walkingTarget()
		-- Nonsense geometry AND inside cooldown: cooldown wins, so no work is wasted.
		local verdict = Claim.resolve(
			claim({ at = 1.0, origin = at(9999, 9999, 9999) }),
			context(history, { lastAcceptedAt = 0.99 })
		)
		expect(verdict.reason).toBe("cooldown")
	end)

	t.test("rejects on the server's own view of the world", function(expect)
		local history = walkingTarget()
		local c = claim({ at = 1.0 })
		expect(Claim.resolve(c, context(history, { weaponEquipped = false })).reason).toBe(
			"not-equipped"
		)
		expect(Claim.resolve(c, context(history, { targetAlive = false })).reason).toBe(
			"target-dead"
		)
		expect(Claim.resolve(c, context(history, { sameTeam = true })).reason).toBe("same-team")
	end)

	t.test("rejects a timestamp in the future", function(expect)
		local history = walkingTarget()
		local verdict = Claim.resolve(claim({ at = 1.5 }), context(history, { now = 1.0 }))
		expect(verdict.reason).toBe("claim-in-future")
		-- A claim slightly AHEAD of our newest sample is not a lie: history is sampled at
		-- a fixed rate, so an honest attack routinely lands between two ticks. Inside the
		-- tolerance it clamps to the newest record instead of being thrown away.
		local close = History.new({ windowSeconds = 0.25 })
		close:Record("target", at(5, 5, 0), 1.0)
		close:Record("attacker", at(0, 5, 0), 1.0)
		local skewed = Claim.resolve(claim({ at = 1.03 }), context(close, { now = 1.05 }))
		expect(skewed.accepted).toBe(true)
		expect(skewed.rewoundTo.X).toBeCloseTo(5)

		-- Far past the newest sample, it is a claim about a future we have no record of.
		local wild = Claim.resolve(claim({ at = 1.4 }), context(close, { now = 1.5 }))
		expect(wild.reason).toBe("claim-in-future")
	end)

	t.test("rejects an unknown target outright, with no policy involved", function(expect)
		local history = walkingTarget()
		local verdict = Claim.resolve(claim({ targetId = "ghost", at = 1.0 }), context(history))
		expect(verdict.reason).toBe("target-unknown")
	end)

	-- THE POLICY EDGE, both branches.
	t.test("the default policy refuses an unverifiable claim", function(expect)
		local history = walkingTarget()
		-- Newest sample is t=1.0 and the window is 0.25, so t=0.5 is past it.
		local verdict = Claim.resolve(claim({ at = 0.5 }), context(history))
		expect(verdict.accepted).toBe(false)
		expect(verdict.reason).toBe("claim-expired")
	end)

	t.test(
		"acceptWithTightRange lets a laggy claim through, against the oldest record",
		function(expect)
			local history = History.new({ windowSeconds = 0.25, sampleRate = 20 })
			history:Record("target", at(8, 5, 0), 0.8)
			history:Record("target", at(9, 5, 0), 1.0)
			history:Record("attacker", at(0, 5, 0), 1.0)

			local generous = table.clone(Claim.DEFAULT_POLICY)
			generous.onExpired = "acceptWithTightRange"

			local verdict = Claim.resolve(claim({ at = 0.1 }), context(history), generous)
			expect(verdict.accepted).toBe(true)
			expect(verdict.reason).toBe("accepted-unverified")
			expect(verdict.unverified).toBe(true)
			-- Resolved against the OLDEST retained position, not an interpolation.
			expect(verdict.rewoundTo.X).toBeCloseTo(8)
		end
	)

	-- The tightened slack is what still guards you when you accept the unverifiable.
	t.test("an unverified claim gets no range slack by default", function(expect)
		local history = History.new({ windowSeconds = 0.25 })
		history:Record("target", at(12, 5, 0), 1.0)
		history:Record("attacker", at(0, 5, 0), 1.0)

		local generous = table.clone(Claim.DEFAULT_POLICY)
		generous.onExpired = "acceptWithTightRange"

		-- 12 studs would pass with the normal 4 slack, but tightRangeSlackStuds is 0.
		local verdict = Claim.resolve(claim({ at = 0.1 }), context(history), generous)
		expect(verdict.accepted).toBe(false)
		expect(verdict.reason).toBe("out-of-range")
	end)

	-- The check people forget. A client can name ANY origin, and without this every range
	-- test measures from a point the attacker invented.
	t.test("rejects a claimed origin far from where the attacker actually was", function(expect)
		local history = walkingTarget()
		-- Attacker was at X=0 the whole time; claim they attacked from beside the target.
		local verdict = Claim.resolve(claim({ at = 1.0, origin = at(38, 5, 0) }), context(history))
		expect(verdict.accepted).toBe(false)
		expect(verdict.reason).toBe("origin-mismatch")
	end)

	t.test("origin slack tolerates honest drift", function(expect)
		local history = History.new({ windowSeconds = 0.5 })
		history:Record("target", at(5, 5, 0), 1.0)
		history:Record("attacker", at(0, 5, 0), 1.0)
		-- 3 studs of drift, inside the 6-stud default.
		local verdict = Claim.resolve(claim({ at = 1.0, origin = at(3, 5, 0) }), context(history))
		expect(verdict.accepted).toBe(true)
	end)

	t.test("an untracked attacker skips the origin check rather than failing shut", function(expect)
		local history = History.new({ windowSeconds = 0.5 })
		history:Record("target", at(5, 5, 0), 1.0)
		-- No attacker history at all - e.g. they just spawned.
		local verdict = Claim.resolve(claim({ at = 1.0 }), context(history))
		expect(verdict.accepted).toBe(true)
	end)

	t.test("an explicit line-of-sight block rejects; nil means not checked", function(expect)
		local history = History.new({ windowSeconds = 0.5 })
		history:Record("target", at(5, 5, 0), 1.0)
		history:Record("attacker", at(0, 5, 0), 1.0)
		local c = claim({ at = 1.0 })
		expect(Claim.resolve(c, context(history, { lineOfSight = false })).reason).toBe(
			"no-line-of-sight"
		)
		expect(Claim.resolve(c, context(history, { lineOfSight = true })).accepted).toBe(true)
		expect(Claim.resolve(c, context(history, { lineOfSight = nil })).accepted).toBe(true)
	end)

	-- forge-guard should catch these at the boundary, but this module is the last line
	-- before damage lands and must be safe alone.
	t.test("refuses malformed claims without throwing", function(expect)
		local history = walkingTarget()
		expect(Claim.resolve(claim({ at = 0 / 0 }), context(history)).reason).toBe(
			"claim-time-not-finite"
		)
		expect(
			Claim.resolve(claim({ at = 1.0, origin = at(0 / 0, 0, 0) }), context(history)).reason
		).toBe("origin-not-finite")
		expect(
			Claim.resolve(
				claim({ at = 1.0, weapon = { range = 0 / 0, cooldown = 0 } }),
				context(history)
			).reason
		).toBe("weapon-range-invalid")
		expect(
			Claim.resolve(
				claim({ at = 1.0, weapon = { range = -5, cooldown = 0 } }),
				context(history)
			).reason
		).toBe("weapon-range-invalid")
	end)

	t.test("the shipped default policy is the conservative one", function(expect)
		expect(Claim.DEFAULT_POLICY.onExpired).toBe("reject")
		expect(Claim.DEFAULT_POLICY.tightRangeSlackStuds).toBe(0)
	end)
end
