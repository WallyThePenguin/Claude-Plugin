--!strict
-- Specs for RateLimit.
--
-- Every one of these would need a real `task.wait` if the clock weren't injected. That is
-- the whole argument for injection: "the bucket refills after 3 seconds" runs instantly.

local RateLimit = require("../src/RateLimit")

-- A clock we drive by hand.
local function fakeClock()
	local now = 0
	return function()
		return now
	end, function(seconds: number)
		now += seconds
	end
end

return function(t)
	t.test("allows a burst up to capacity then rejects", function(expect)
		local clock = fakeClock()
		local limiter = RateLimit.new({ rate = 1, burst = 3 }, clock)
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(false)
	end)

	t.test("refills continuously at the configured rate", function(expect)
		local clock, advance = fakeClock()
		local limiter = RateLimit.new({ rate = 2, burst = 2 }, clock)
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(false)

		advance(0.5) -- 0.5s at 2/s == exactly one token
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(false)
	end)

	t.test("refill is capped at burst, so idling does not bank tokens", function(expect)
		local clock, advance = fakeClock()
		local limiter = RateLimit.new({ rate = 10, burst = 2 }, clock)
		advance(100) -- long idle
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(true)
		expect(limiter:Consume("p")).toBe(false)
	end)

	t.test("buckets are independent per key", function(expect)
		local clock = fakeClock()
		local limiter = RateLimit.new({ rate = 1, burst = 1 }, clock)
		expect(limiter:Consume("a")).toBe(true)
		expect(limiter:Consume("a")).toBe(false)
		-- One player exhausting their budget must not affect anyone else.
		expect(limiter:Consume("b")).toBe(true)
	end)

	t.test("cost lets one call weigh more than another", function(expect)
		local clock = fakeClock()
		local limiter = RateLimit.new({ rate = 1, burst = 10 }, clock)
		expect(limiter:Consume("p", 8)).toBe(true)
		expect(limiter:Consume("p", 8)).toBe(false)
		expect(limiter:Consume("p", 2)).toBe(true)
	end)

	t.test("counts rejections, which is the signal worth acting on", function(expect)
		local clock = fakeClock()
		local limiter = RateLimit.new({ rate = 1, burst = 1 }, clock)
		limiter:Consume("p")
		limiter:Consume("p")
		limiter:Consume("p")
		expect(limiter:Rejections("p")).toBe(2)
		expect(limiter:Rejections("never-seen")).toBe(0)
	end)

	-- A clock that goes backwards must not drain the bucket. os.clock is monotonic, but
	-- a caller may pass something that is not, and silently rate-limiting everyone is a
	-- worse outcome than ignoring the anomaly.
	t.test("survives a non-monotonic clock without draining", function(expect)
		local now = 100
		local limiter = RateLimit.new({ rate = 1, burst = 2 }, function()
			return now
		end)
		expect(limiter:Consume("p")).toBe(true)
		now = 50
		expect(limiter:Consume("p")).toBe(true)
	end)

	t.test("Forget drops a key so per-player tables cannot leak", function(expect)
		local clock = fakeClock()
		local limiter = RateLimit.new({ rate = 1, burst = 1 }, clock)
		limiter:Consume("p")
		limiter:Consume("p")
		expect(limiter:Count()).toBe(1)
		limiter:Forget("p")
		expect(limiter:Count()).toBe(0)
		expect(limiter:Rejections("p")).toBe(0)
		-- A fresh bucket starts full again.
		expect(limiter:Consume("p")).toBe(true)
	end)

	t.test("Prune reaps idle keys as a safety net", function(expect)
		local clock, advance = fakeClock()
		local limiter = RateLimit.new({ rate = 1, burst = 1, idleTimeout = 10 }, clock)
		limiter:Consume("stale")
		advance(11)
		limiter:Consume("fresh")
		expect(limiter:Count()).toBe(2)
		expect(limiter:Prune()).toBe(1)
		expect(limiter:Count()).toBe(1)
	end)

	t.test("rejects a non-positive rate or burst at construction", function(expect)
		local clock = fakeClock()
		expect(function()
			RateLimit.new({ rate = 0 }, clock)
		end).toThrow("rate must be positive")
		expect(function()
			RateLimit.new({ rate = 1, burst = 0 }, clock)
		end).toThrow("burst must be positive")
	end)
end
