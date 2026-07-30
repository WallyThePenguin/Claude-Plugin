--!strict
-- Machine: the round/match lifecycle, as an explicit guarded state machine.
--
-- WHY A MACHINE AND NOT A LOOP. The obvious implementation is a `while true` with
-- `task.wait`s (this repo's own P1 skeleton is exactly that). It works right up until you
-- need anything real: aborting a round when players leave, an admin force-ending, a rejoin
-- mid-match, or a test. A coroutine parked inside a wait cannot be asked what phase it is
-- in, cannot be interrupted, and cannot be tested without real time passing.
--
-- So the lifecycle is data: a phase, an entry timestamp, and a table of legal transitions.
-- `Tick(now, world)` is a pure function of (state, time, world) -> transitions. That makes
-- the whole thing inspectable, interruptible, and testable in microseconds.
--
-- Pure Luau. The clock is a parameter, not a service. Nothing here touches Roblox - the
-- adapter in RoundService.luau does that, and it is the only untested file in the package.

export type Phase = "idle" | "queueing" | "intermission" | "active" | "results"

export type Config = {
	-- Players needed before a match can start.
	minPlayers: number,
	-- Cap on participants locked into one match.
	maxPlayers: number,
	-- Countdown after the queue fills. Players are locked in for this window, which is
	-- what lets clients preload and show a "starting in" counter.
	intermissionSeconds: number,
	-- Hard ceiling on a round. A round that cannot end on its own must still end.
	roundSeconds: number,
	-- How long results stay up before returning to idle.
	resultsSeconds: number,
	-- Participants below this mid-round aborts it. Defaults to 1: a one-player arena is
	-- a player standing in an empty room, which is worse than a clean abort.
	abortBelowPlayers: number?,
}

-- What the caller knows about the world this tick. The machine never reaches out for any
-- of it, which is precisely why it is testable.
export type World = {
	-- Players waiting in the queue.
	queued: number,
	-- Players locked into the current match. Only meaningful from intermission onward.
	participants: number,
	-- Has the win condition been met? Checked in `active` only.
	objectiveMet: boolean?,
}

export type Reason =
	"queue-opened"
	| "queue-emptied"
	| "queue-filled"
	| "queue-shrank"
	| "countdown-elapsed"
	| "objective-met"
	| "time-limit"
	| "aborted-too-few-players"
	| "results-elapsed"
	| "forced"

export type Transition = {
	from: Phase,
	to: Phase,
	at: number,
	reason: Reason,
}

-- Every legal edge, in one place. A transition not listed here cannot happen, which means
-- a bug shows up as a loud error at the transition rather than as a game stuck in a phase
-- nobody can name.
local LEGAL: { [Phase]: { [Phase]: true } } = {
	idle = { queueing = true },
	queueing = { idle = true, intermission = true },
	-- Back to queueing if the lobby shrinks before the countdown finishes.
	intermission = { queueing = true, active = true },
	active = { results = true },
	results = { idle = true, queueing = true },
}

-- Phases that end on a timer, and which config field sets the duration.
local DURATION_FIELD: { [Phase]: string } = {
	intermission = "intermissionSeconds",
	active = "roundSeconds",
	results = "resultsSeconds",
}

local Machine = {}
Machine.__index = Machine

export type Machine = {
	Phase: (self: Machine) -> Phase,
	EnteredAt: (self: Machine) -> number,
	Elapsed: (self: Machine, now: number) -> number,
	Remaining: (self: Machine, now: number) -> number?,
	Tick: (self: Machine, now: number, world: World) -> { Transition },
	Force: (self: Machine, to: Phase, now: number) -> Transition,
	CanTransition: (self: Machine, to: Phase) -> boolean,
	Round: (self: Machine) -> number,
}

function Machine.new(config: Config, startedAt: number?): Machine
	assert(config.minPlayers >= 1, "minPlayers must be at least 1")
	assert(config.maxPlayers >= config.minPlayers, "maxPlayers must be >= minPlayers")
	assert(config.intermissionSeconds >= 0, "intermissionSeconds must not be negative")
	assert(config.roundSeconds > 0, "roundSeconds must be positive")
	assert(config.resultsSeconds >= 0, "resultsSeconds must not be negative")

	return (
		setmetatable({
			_config = config,
			_phase = "idle" :: Phase,
			_enteredAt = startedAt or 0,
			-- Increments on each match start. Useful as a match id, and as a guard
			-- against a late packet from the previous round being applied to this one.
			_round = 0,
		}, Machine) :: any
	) :: Machine
end

function Machine.Phase(self: Machine): Phase
	return (self :: any)._phase
end

function Machine.EnteredAt(self: Machine): number
	return (self :: any)._enteredAt
end

function Machine.Round(self: Machine): number
	return (self :: any)._round
end

function Machine.Elapsed(self: Machine, now: number): number
	return math.max(0, now - (self :: any)._enteredAt)
end

--[[
	Seconds left in the current phase, or nil for phases that end on an event rather than a
	clock (`idle`, `queueing`). Clamped at zero - never negative, so a UI can bind to it
	directly.
]]
function Machine.Remaining(self: Machine, now: number): number?
	local this = self :: any
	local field = DURATION_FIELD[this._phase]
	if field == nil then
		return nil
	end
	local duration = this._config[field] :: number
	return math.max(0, duration - self:Elapsed(now))
end

function Machine.CanTransition(self: Machine, to: Phase): boolean
	local allowed = LEGAL[(self :: any)._phase]
	return allowed ~= nil and allowed[to] == true
end

function Machine._move(self: any, to: Phase, now: number, reason: Reason): Transition
	local from: Phase = self._phase
	if not self:CanTransition(to) then
		error(`illegal transition {from} -> {to} ({reason})`, 0)
	end
	self._phase = to
	self._enteredAt = now
	if to == "active" then
		self._round += 1
	end
	return { from = from, to = to, at = now, reason = reason }
end

--[[
	Advance the machine. Returns every transition that fired, in order - usually zero or
	one, but a cascade is possible and correct (results elapsing straight into queueing
	because players are already waiting).

	Loops until the machine settles rather than resolving one edge per call, so a caller
	ticking at 10 Hz behaves identically to one ticking at 60 Hz. A fixed iteration cap
	guards against a config that could otherwise cycle forever.
]]
function Machine.Tick(self: Machine, now: number, world: World): { Transition }
	local this = self :: any
	local transitions: { Transition } = {}

	for _ = 1, 8 do
		local moved = Machine._step(this, now, world)
		if moved == nil then
			break
		end
		table.insert(transitions, moved)
	end

	return transitions
end

function Machine._step(this: any, now: number, world: World): Transition?
	local config: Config = this._config
	local phase: Phase = this._phase
	local elapsed = math.max(0, now - this._enteredAt)

	if phase == "idle" then
		if world.queued > 0 then
			return Machine._move(this, "queueing", now, "queue-opened")
		end
		return nil
	end

	if phase == "queueing" then
		if world.queued >= config.minPlayers then
			return Machine._move(this, "intermission", now, "queue-filled")
		end
		if world.queued <= 0 then
			return Machine._move(this, "idle", now, "queue-emptied")
		end
		return nil
	end

	if phase == "intermission" then
		-- The lobby can shrink while the countdown runs. Falling back to queueing is
		-- kinder than starting a match that will abort immediately.
		if world.queued < config.minPlayers then
			return Machine._move(this, "queueing", now, "queue-shrank")
		end
		if elapsed >= config.intermissionSeconds then
			return Machine._move(this, "active", now, "countdown-elapsed")
		end
		return nil
	end

	if phase == "active" then
		-- Objective before the timer: a round won at 0.1s left ended because it was won,
		-- and the reason is what the results screen reports.
		if world.objectiveMet then
			return Machine._move(this, "results", now, "objective-met")
		end
		local floor = config.abortBelowPlayers or 1
		if world.participants < floor then
			return Machine._move(this, "results", now, "aborted-too-few-players")
		end
		if elapsed >= config.roundSeconds then
			return Machine._move(this, "results", now, "time-limit")
		end
		return nil
	end

	if phase == "results" then
		if elapsed >= config.resultsSeconds then
			-- Straight back to queueing when players are already waiting: making them
			-- sit through an idle phase they cannot see is dead air.
			if world.queued > 0 then
				return Machine._move(this, "queueing", now, "results-elapsed")
			end
			return Machine._move(this, "idle", now, "results-elapsed")
		end
		return nil
	end

	return nil
end

--[[
	Force a transition - admin commands, shutdown, tests. Still validated against the legal
	edges: forcing is for skipping ahead, not for inventing states.
]]
function Machine.Force(self: Machine, to: Phase, now: number): Transition
	return Machine._move(self :: any, to, now, "forced")
end

return Machine
