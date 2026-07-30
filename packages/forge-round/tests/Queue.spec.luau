--!strict
-- Specs for Queue.

local Queue = require("../src/Queue")

return function(t)
	t.test("joins and reports membership and size", function(expect)
		local queue = Queue.new()
		expect(queue:Join("a", 0)).toBe(true)
		expect(queue:Join("b", 1)).toBe(true)
		expect(queue:Size()).toBe(2)
		expect(queue:Contains("a")).toBe(true)
		expect(queue:Contains("z")).toBe(false)
	end)

	-- A double-click on the queue button is a UI event, not an exploit, and it must not
	-- cost the player their place in line.
	t.test("joining twice is a no-op that preserves position", function(expect)
		local queue = Queue.new()
		queue:Join("a", 0)
		queue:Join("b", 1)
		expect(queue:Join("a", 50)).toBe(false)
		expect(queue:Size()).toBe(2)
		expect(queue:WaitedFor("a", 50)).toBe(50)
		expect(queue:Peek(2)).toEqual({ "a", "b" })
	end)

	t.test("leaving is idempotent", function(expect)
		local queue = Queue.new()
		queue:Join("a", 0)
		expect(queue:Leave("a")).toBe(true)
		expect(queue:Leave("a")).toBe(false)
		expect(queue:Size()).toBe(0)
		expect(queue:Contains("a")).toBe(false)
	end)

	t.test("leaving from the middle preserves the order of everyone else", function(expect)
		local queue = Queue.new()
		queue:Join("a", 0)
		queue:Join("b", 1)
		queue:Join("c", 2)
		queue:Leave("b")
		expect(queue:Peek(3)).toEqual({ "a", "c" })
	end)

	-- Fairness by wait time is the property players notice immediately when it is missing.
	t.test("Take pops the longest-waiting first", function(expect)
		local queue = Queue.new()
		queue:Join("first", 0)
		queue:Join("second", 5)
		queue:Join("third", 10)
		expect(queue:Take(2)).toEqual({ "first", "second" })
		expect(queue:Size()).toBe(1)
		expect(queue:Contains("first")).toBe(false)
	end)

	-- The caller decides whether a short match is acceptable; that policy lives in the
	-- machine's minPlayers, not here.
	t.test("Take returns fewer than asked rather than refusing", function(expect)
		local queue = Queue.new()
		queue:Join("a", 0)
		expect(queue:Take(5)).toEqual({ "a" })
		expect(queue:Take(5)).toEqual({})
		expect(queue:Size()).toBe(0)
	end)

	t.test("Peek does not remove anyone", function(expect)
		local queue = Queue.new()
		queue:Join("a", 0)
		queue:Join("b", 1)
		expect(queue:Peek(1)).toEqual({ "a" })
		expect(queue:Size()).toBe(2)
	end)

	t.test("tracks per-player wait time", function(expect)
		local queue = Queue.new()
		queue:Join("a", 10)
		expect(queue:WaitedFor("a", 40)).toBe(30)
		expect(queue:WaitedFor("nobody", 40)).toBeNil()
		-- A clock that jumped back must not report a negative wait.
		expect(queue:WaitedFor("a", 5)).toBe(0)
	end)

	-- Average wait hides the player who has been waiting four minutes, and that player is
	-- the one who leaves. Alarm on the longest.
	t.test("LongestWait reports the oldest entry, zero when empty", function(expect)
		local queue = Queue.new()
		expect(queue:LongestWait(100)).toBe(0)
		queue:Join("old", 0)
		queue:Join("new", 90)
		expect(queue:LongestWait(100)).toBe(100)
		queue:Take(1)
		expect(queue:LongestWait(100)).toBe(10)
	end)

	-- An unbounded queue is a memory target.
	t.test("capacity is enforced", function(expect)
		local queue = Queue.new({ capacity = 2 })
		expect(queue:Join("a", 0)).toBe(true)
		expect(queue:Join("b", 0)).toBe(true)
		expect(queue:Join("c", 0)).toBe(false)
		expect(queue:Size()).toBe(2)
		-- Space frees up when someone leaves.
		queue:Leave("a")
		expect(queue:Join("c", 0)).toBe(true)
	end)

	t.test("Clear empties both the order and the membership index", function(expect)
		local queue = Queue.new()
		queue:Join("a", 0)
		queue:Join("b", 0)
		queue:Clear()
		expect(queue:Size()).toBe(0)
		expect(queue:Contains("a")).toBe(false)
		-- And rejoining works, which is what catches a stale membership index.
		expect(queue:Join("a", 1)).toBe(true)
	end)

	t.test("rejects a nonsense capacity", function(expect)
		expect(function()
			Queue.new({ capacity = 0 })
		end).toThrow("capacity")
	end)
end
