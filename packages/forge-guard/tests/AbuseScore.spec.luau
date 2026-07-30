--!strict
-- Specs for AbuseScore.

local AbuseScore = require("../src/AbuseScore")

local function fakeClock()
	local now = 0
	return function()
		return now
	end, function(seconds: number)
		now += seconds
	end
end

return function(t)
	t.test("accumulates weighted reports", function(expect)
		local clock = fakeClock()
		local score = AbuseScore.new({ threshold = 10, decayPerSecond = 0 }, clock)
		expect(score:Report("p", "speed")).toBe(1)
		expect(score:Report("p", "speed", 4)).toBe(5)
		expect(score:Score("p")).toBe(5)
	end)

	t.test("an unknown key scores zero without creating an entry", function(expect)
		local clock = fakeClock()
		local score = AbuseScore.new({ threshold = 5, decayPerSecond = 1 }, clock)
		expect(score:Score("nobody")).toBe(0)
		expect(score:Exceeded("nobody")).toBe(false)
	end)

	t.test("Exceeded trips at the threshold, inclusive", function(expect)
		local clock = fakeClock()
		local score = AbuseScore.new({ threshold = 3, decayPerSecond = 0 }, clock)
		score:Report("p", "rate", 2)
		expect(score:Exceeded("p")).toBe(false)
		score:Report("p", "rate", 1)
		expect(score:Exceeded("p")).toBe(true)
	end)

	-- The whole reason this isn't a counter: isolated evidence has to age out, or every
	-- long session eventually crosses any threshold.
	t.test("decays over time and floors at zero", function(expect)
		local clock, advance = fakeClock()
		local score = AbuseScore.new({ threshold = 10, decayPerSecond = 1 }, clock)
		score:Report("p", "speed", 5)
		advance(2)
		expect(score:Score("p")).toBe(3)
		advance(100)
		expect(score:Score("p")).toBe(0)
	end)

	t.test(
		"a sustained pattern crosses the threshold where isolated spikes do not",
		function(expect)
			local clock, advance = fakeClock()
			local score = AbuseScore.new({ threshold = 5, decayPerSecond = 1 }, clock)

			-- Lag: one violation every 10 seconds. Decays away between each.
			for _ = 1, 5 do
				score:Report("laggy", "speed")
				advance(10)
			end
			expect(score:Exceeded("laggy")).toBe(false)

			-- A cheat: eight inside two seconds. Note that decay applies BEFORE each
			-- report, so N weight-1 reports never reach a score of N - eight at 0.2s
			-- spacing peaks around 6.6 against a threshold of 5.
			for _ = 1, 8 do
				score:Report("cheater", "speed")
				advance(0.2)
			end
			expect(score:Exceeded("cheater")).toBe(true)
		end
	)

	-- Without a ceiling, a burst banks a debt that keeps a player flagged long after
	-- they stopped - which is indistinguishable from a false positive to the player.
	t.test("caps the score so a burst cannot bank an unpayable debt", function(expect)
		local clock, advance = fakeClock()
		local score = AbuseScore.new({ threshold = 5, decayPerSecond = 1, maxScore = 8 }, clock)
		for _ = 1, 100 do
			score:Report("p", "speed")
		end
		expect(score:Score("p")).toBe(8)
		advance(9)
		expect(score:Score("p")).toBe(0)
	end)

	t.test("Breakdown reports what they were doing, not just how much", function(expect)
		local clock = fakeClock()
		local score = AbuseScore.new({ threshold = 20, decayPerSecond = 0 }, clock)
		score:Report("p", "speed")
		score:Report("p", "speed")
		score:Report("p", "reach", 3)
		expect(score:Breakdown("p")).toEqual({ speed = 2, reach = 1 })
		expect(score:Breakdown("nobody")).toEqual({})
	end)

	t.test("Breakdown returns a copy, so callers cannot mutate internal state", function(expect)
		local clock = fakeClock()
		local score = AbuseScore.new({ threshold = 20, decayPerSecond = 0 }, clock)
		score:Report("p", "speed")
		local snapshot = score:Breakdown("p")
		snapshot.speed = 999
		expect(score:Breakdown("p").speed).toBe(1)
	end)

	t.test("Forget clears a key entirely", function(expect)
		local clock = fakeClock()
		local score = AbuseScore.new({ threshold = 2, decayPerSecond = 0 }, clock)
		score:Report("p", "speed", 5)
		expect(score:Exceeded("p")).toBe(true)
		score:Forget("p")
		expect(score:Score("p")).toBe(0)
		expect(score:Breakdown("p")).toEqual({})
	end)

	t.test("Prune reaps idle keys", function(expect)
		local clock, advance = fakeClock()
		local score = AbuseScore.new({ threshold = 5, decayPerSecond = 0, idleTimeout = 10 }, clock)
		score:Report("stale", "speed")
		advance(11)
		score:Report("fresh", "speed")
		expect(score:Prune()).toBe(1)
		expect(score:Score("stale")).toBe(0)
		expect(score:Score("fresh")).toBe(1)
	end)

	t.test("rejects nonsense configuration at construction", function(expect)
		local clock = fakeClock()
		expect(function()
			AbuseScore.new({ threshold = 0, decayPerSecond = 1 }, clock)
		end).toThrow("threshold must be positive")
		expect(function()
			AbuseScore.new({ threshold = 1, decayPerSecond = -1 }, clock)
		end).toThrow("decayPerSecond")
	end)
end
