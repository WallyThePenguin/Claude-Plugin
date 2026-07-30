--!strict
-- Specs for History.

local History = require("../src/History")

local function at(x: number, y: number, z: number)
	return { X = x, Y = y, Z = z }
end

return function(t)
	t.test("records and reads back an exact sample", function(expect)
		local history = History.new({ windowSeconds = 1, sampleRate = 10 })
		history:Record("a", at(0, 5, 0), 1.0)
		history:Record("a", at(10, 5, 0), 1.5)
		local position = history:SampleAt("a", 1.5)
		expect(position.X).toBe(10)
		expect(history:Count("a")).toBe(2)
	end)

	-- The core of lag compensation: reconstructing where someone was between two samples.
	t.test("interpolates linearly between samples", function(expect)
		local history = History.new({ windowSeconds = 1, sampleRate = 10 })
		history:Record("a", at(0, 0, 0), 1.0)
		history:Record("a", at(10, 20, -30), 2.0)
		local position = history:SampleAt("a", 1.25)
		expect(position.X).toBeCloseTo(2.5)
		expect(position.Y).toBeCloseTo(5)
		expect(position.Z).toBeCloseTo(-7.5)
	end)

	t.test("interpolates across several samples", function(expect)
		local history = History.new({ windowSeconds = 2, sampleRate = 10 })
		for step = 0, 10 do
			history:Record("a", at(step * 10, 0, 0), step * 0.1)
		end
		expect(history:SampleAt("a", 0.55).X).toBeCloseTo(55)
		expect(history:SampleAt("a", 0.0).X).toBeCloseTo(0)
		expect(history:SampleAt("a", 1.0).X).toBeCloseTo(100)
	end)

	t.test("an unknown entity reports unknown, not a guess", function(expect)
		local history = History.new({ windowSeconds = 1 })
		local position, reason = history:SampleAt("ghost", 1)
		expect(position).toBeNil()
		expect(reason).toBe("unknown")
	end)

	-- A client claiming the future is desynced or lying; either way we cannot verify it.
	t.test("rejects a lookup ahead of the newest sample", function(expect)
		local history = History.new({ windowSeconds = 1 })
		history:Record("a", at(0, 0, 0), 10)
		local position, reason = history:SampleAt("a", 10.5)
		expect(position).toBeNil()
		expect(reason).toBe("future")
	end)

	-- The bound. Without it a client could claim a hit on someone who moved away seconds
	-- ago; `expired` is the signal that hands the decision to Claim's policy.
	t.test("rejects a lookup older than the window as expired", function(expect)
		local history = History.new({ windowSeconds = 0.25, sampleRate = 20 })
		for step = 0, 20 do
			history:Record("a", at(step, 0, 0), step * 0.05)
		end
		-- Newest is at 1.0, so the window covers back to 0.75.
		expect(history:SampleAt("a", 0.8)).toBeTruthy()
		local position, reason = history:SampleAt("a", 0.5)
		expect(position).toBeNil()
		expect(reason).toBe("expired")
	end)

	-- Measured back from the newest RECORD, not from wall-clock now, so the verdict does
	-- not change based on when the caller happens to ask.
	t.test("the window is measured from the newest sample", function(expect)
		local history = History.new({ windowSeconds = 0.25 })
		history:Record("a", at(0, 0, 0), 100)
		history:Record("a", at(1, 0, 0), 100.2)
		expect(history:SampleAt("a", 100.05)).toBeTruthy()
		local _, reason = history:SampleAt("a", 99.9)
		expect(reason).toBe("expired")
	end)

	t.test(
		"an entity that only just appeared reports expired, not a wrong position",
		function(expect)
			local history = History.new({ windowSeconds = 1 })
			history:Record("a", at(0, 0, 0), 10)
			local position, reason = history:SampleAt("a", 9.5)
			expect(position).toBeNil()
			expect(reason).toBe("expired")
		end
	)

	t.test("the ring buffer bounds memory and drops the oldest samples", function(expect)
		local history = History.new({ windowSeconds = 0.2, sampleRate = 10 })
		for step = 1, 500 do
			history:Record("a", at(step, 0, 0), step * 0.1)
		end
		-- Capacity is ceil(0.2 * 10) + 2 == 4, so 500 samples must not grow the buffer.
		expect(history:Count("a")).toBe(4)
		local oldest, newest = history:Span("a")
		expect(newest).toBeCloseTo(50)
		-- Four retained samples spaced 0.1s apart, ending at 50.0.
		expect(oldest).toBeCloseTo(49.7, 1e-6)
	end)

	t.test("reading still works after the buffer has wrapped", function(expect)
		local history = History.new({ windowSeconds = 1, sampleRate = 5 })
		for step = 1, 100 do
			history:Record("a", at(step * 10, 0, 0), step * 0.2)
		end
		local newest = history:Newest("a")
		expect(newest.at).toBeCloseTo(20)
		expect(newest.position.X).toBeCloseTo(1000)
		-- An interpolated read inside the retained span, post-wrap.
		expect(history:SampleAt("a", 19.9).X).toBeCloseTo(995)
	end)

	-- Interpolation assumes ordering, so an out-of-order sample is dropped rather than
	-- allowed to corrupt every later lookup.
	t.test("silently drops an out-of-order sample", function(expect)
		local history = History.new({ windowSeconds = 1 })
		history:Record("a", at(0, 0, 0), 10)
		history:Record("a", at(99, 0, 0), 9) -- older than newest
		expect(history:Count("a")).toBe(1)
		expect(history:Newest("a").position.X).toBe(0)
	end)

	t.test("drops samples with non-finite positions or times", function(expect)
		local history = History.new({ windowSeconds = 1 })
		history:Record("a", at(0 / 0, 0, 0), 1)
		history:Record("a", at(0, math.huge, 0), 1)
		history:Record("a", at(0, 0, 0), 0 / 0)
		expect(history:Count("a")).toBe(0)
	end)

	t.test("a non-finite lookup time is treated as unverifiable", function(expect)
		local history = History.new({ windowSeconds = 1 })
		history:Record("a", at(0, 0, 0), 1)
		local position, reason = history:SampleAt("a", 0 / 0)
		expect(position).toBeNil()
		expect(reason).toBe("future")
	end)

	t.test("stores a copy of the position", function(expect)
		local history = History.new({ windowSeconds = 1 })
		local source = at(1, 2, 3)
		history:Record("a", source, 1)
		source.X = 999
		expect(history:Newest("a").position.X).toBe(1)
	end)

	t.test("entities are independent, and Forget drops one", function(expect)
		local history = History.new({ windowSeconds = 1 })
		history:Record("a", at(1, 0, 0), 1)
		history:Record("b", at(2, 0, 0), 1)
		expect(history:Entities()).toBe(2)
		expect(history:SampleAt("b", 1).X).toBe(2)
		history:Forget("a")
		expect(history:Entities()).toBe(1)
		local _, reason = history:SampleAt("a", 1)
		expect(reason).toBe("unknown")
	end)

	t.test("handles duplicate timestamps without dividing by zero", function(expect)
		local history = History.new({ windowSeconds = 1 })
		history:Record("a", at(0, 0, 0), 1)
		history:Record("a", at(5, 0, 0), 1)
		expect(history:SampleAt("a", 1)).toBeTruthy()
	end)

	t.test("rejects nonsense configuration", function(expect)
		expect(function()
			History.new({ windowSeconds = 0 })
		end).toThrow("windowSeconds must be positive")
		expect(function()
			History.new({ windowSeconds = 1, sampleRate = 0 })
		end).toThrow("sampleRate must be positive")
	end)
end
