--!strict
-- Specs for Machine.
--
-- Every one of these would need real seconds to pass if the lifecycle were a `while true`
-- loop with `task.wait`s. That is the argument for making it data.

local Machine = require("../src/Machine")

local CONFIG = {
	minPlayers = 2,
	maxPlayers = 8,
	intermissionSeconds = 5,
	roundSeconds = 60,
	resultsSeconds = 8,
}

local function world(queued: number, participants: number, objectiveMet: boolean?)
	return { queued = queued, participants = participants, objectiveMet = objectiveMet }
end

local function reasons(transitions)
	local out = {}
	for _, transition in transitions do
		table.insert(out, `{transition.from}->{transition.to}:{transition.reason}`)
	end
	return out
end

return function(t)
	t.test("starts idle", function(expect)
		local machine = Machine.new(CONFIG)
		expect(machine:Phase()).toBe("idle")
		expect(machine:Round()).toBe(0)
		-- Idle has no timer, so nothing to count down.
		expect(machine:Remaining(0)).toBeNil()
	end)

	t.test("idle stays idle with nobody queued", function(expect)
		local machine = Machine.new(CONFIG)
		expect(#machine:Tick(1, world(0, 0))).toBe(0)
		expect(machine:Phase()).toBe("idle")
	end)

	t.test("one player opens the queue", function(expect)
		local machine = Machine.new(CONFIG)
		expect(reasons(machine:Tick(1, world(1, 0)))).toEqual({ "idle->queueing:queue-opened" })
		expect(machine:Phase()).toBe("queueing")
	end)

	t.test("the queue emptying returns to idle", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(1, world(1, 0))
		expect(reasons(machine:Tick(2, world(0, 0)))).toEqual({ "queueing->idle:queue-emptied" })
	end)

	t.test("reaching minPlayers starts the countdown", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(1, world(1, 0))
		expect(reasons(machine:Tick(2, world(2, 0)))).toEqual({
			"queueing->intermission:queue-filled",
		})
		expect(machine:Remaining(2)).toBe(5)
		expect(machine:Remaining(4)).toBe(3)
	end)

	t.test("the countdown elapsing starts the round and bumps the round number", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(1, world(2, 0))
		expect(machine:Phase()).toBe("intermission")
		expect(#machine:Tick(4, world(2, 2))).toBe(0) -- countdown still running
		expect(reasons(machine:Tick(6, world(2, 2)))).toEqual({
			"intermission->active:countdown-elapsed",
		})
		expect(machine:Round()).toBe(1)
	end)

	-- Kinder than starting a match that would abort on its first tick.
	t.test("a lobby shrinking during the countdown falls back to queueing", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(1, world(2, 0))
		expect(reasons(machine:Tick(2, world(1, 0)))).toEqual({
			"intermission->queueing:queue-shrank",
		})
		expect(machine:Phase()).toBe("queueing")
	end)

	t.test("the objective ending a round beats the time limit", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(0, world(2, 0))
		machine:Tick(5, world(2, 2))
		expect(machine:Phase()).toBe("active")
		-- Won with most of the round still left; the reason is what results reports.
		expect(reasons(machine:Tick(20, world(0, 2, true)))).toEqual({
			"active->results:objective-met",
		})
	end)

	t.test("a round that cannot end on its own still ends", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(0, world(2, 0))
		machine:Tick(5, world(2, 2))
		expect(#machine:Tick(60, world(0, 2, false))).toBe(0)
		expect(reasons(machine:Tick(65, world(0, 2, false)))).toEqual({
			"active->results:time-limit",
		})
	end)

	-- A one-player arena is a player standing in an empty room. Abort is the kinder bug.
	t.test("participants dropping below the floor aborts the round", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(0, world(2, 0))
		machine:Tick(5, world(2, 2))
		expect(reasons(machine:Tick(10, world(0, 0, false)))).toEqual({
			"active->results:aborted-too-few-players",
		})
	end)

	t.test("abortBelowPlayers is configurable", function(expect)
		local config = table.clone(CONFIG)
		config.abortBelowPlayers = 2
		local machine = Machine.new(config)
		machine:Tick(0, world(2, 0))
		machine:Tick(5, world(2, 2))
		-- One player left of two: below the floor now, where the default would continue.
		expect(reasons(machine:Tick(10, world(0, 1, false)))).toEqual({
			"active->results:aborted-too-few-players",
		})
	end)

	t.test("results return to idle when nobody is waiting", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(0, world(2, 0))
		machine:Tick(5, world(2, 2))
		machine:Tick(10, world(0, 2, true))
		expect(machine:Phase()).toBe("results")
		expect(#machine:Tick(15, world(0, 0))).toBe(0)
		expect(reasons(machine:Tick(18, world(0, 0)))).toEqual({ "results->idle:results-elapsed" })
	end)

	-- Making players sit through an invisible idle phase is dead air.
	t.test("results go straight back to queueing when players are waiting", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(0, world(2, 0))
		machine:Tick(5, world(2, 2))
		machine:Tick(10, world(1, 2, true))
		expect(reasons(machine:Tick(18, world(1, 0)))).toEqual({
			"results->queueing:results-elapsed",
		})
	end)

	-- A caller ticking at 10 Hz must behave identically to one ticking at 60 Hz, so a
	-- single Tick resolves the whole cascade.
	t.test("one Tick resolves a cascade rather than one edge per call", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Tick(0, world(2, 0))
		machine:Tick(5, world(2, 2))
		machine:Tick(10, world(2, 2, true))
		expect(machine:Phase()).toBe("results")
		-- Results elapse AND the queue is full: both edges in one tick.
		expect(reasons(machine:Tick(30, world(2, 0)))).toEqual({
			"results->queueing:results-elapsed",
			"queueing->intermission:queue-filled",
		})
		expect(machine:Phase()).toBe("intermission")
	end)

	t.test("a full lifecycle from cold start increments the round each match", function(expect)
		local machine = Machine.new(CONFIG)
		local now = 0
		for match = 1, 3 do
			machine:Tick(now, world(2, 0))
			now += CONFIG.intermissionSeconds
			machine:Tick(now, world(2, 2))
			expect(machine:Phase()).toBe("active")
			expect(machine:Round()).toBe(match)
			now += 10
			machine:Tick(now, world(2, 2, true))
			now += CONFIG.resultsSeconds
			machine:Tick(now, world(0, 0))
			expect(machine:Phase()).toBe("idle")
		end
	end)

	-- The point of the transition table: a bug is a loud error at the transition, not a
	-- game stuck in a phase nobody can name.
	t.test("an illegal forced transition errors", function(expect)
		local machine = Machine.new(CONFIG)
		expect(machine:Phase()).toBe("idle")
		expect(function()
			machine:Force("active", 1)
		end).toThrow("illegal transition idle -> active")
		expect(machine:CanTransition("queueing")).toBe(true)
		expect(machine:CanTransition("results")).toBe(false)
	end)

	t.test("Force skips ahead through a legal edge", function(expect)
		local machine = Machine.new(CONFIG)
		local transition = machine:Force("queueing", 3)
		expect(transition.reason).toBe("forced")
		expect(transition.at).toBe(3)
		expect(machine:Phase()).toBe("queueing")
		expect(machine:EnteredAt()).toBe(3)
	end)

	t.test("Remaining clamps at zero so a UI can bind to it directly", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Force("queueing", 0)
		machine:Force("intermission", 0)
		expect(machine:Remaining(0)).toBe(5)
		expect(machine:Remaining(99)).toBe(0)
	end)

	t.test("Elapsed never goes negative on a clock that jumped back", function(expect)
		local machine = Machine.new(CONFIG)
		machine:Force("queueing", 100)
		expect(machine:Elapsed(50)).toBe(0)
	end)

	t.test("rejects incoherent configuration", function(expect)
		expect(function()
			Machine.new({
				minPlayers = 0,
				maxPlayers = 8,
				intermissionSeconds = 1,
				roundSeconds = 1,
				resultsSeconds = 1,
			})
		end).toThrow("minPlayers")
		expect(function()
			Machine.new({
				minPlayers = 4,
				maxPlayers = 2,
				intermissionSeconds = 1,
				roundSeconds = 1,
				resultsSeconds = 1,
			})
		end).toThrow("maxPlayers")
		expect(function()
			Machine.new({
				minPlayers = 2,
				maxPlayers = 8,
				intermissionSeconds = 1,
				roundSeconds = 0,
				resultsSeconds = 1,
			})
		end).toThrow("roundSeconds")
	end)
end
