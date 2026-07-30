--!strict
-- RoundService: the Roblox adapter around Machine and Queue.
--
-- This is the ONLY file in the package that touches Roblox, and therefore the only one not
-- covered by specs. Everything it does is glue: read the clock, tick the machine, fan the
-- transitions out as signals, and clean up. All the logic it is gluing is in Machine.luau
-- and Queue.luau, which are pure and specced.
--
-- It consumes two Forest packages rather than reimplementing them - `sleitnick/signal` and
-- `sleitnick/trove`, both mirrored from Wally. Signals and cleanup are exactly the kind of
-- solved problem where writing our own buys a name and a maintenance bill. Note the
-- requires are RELATIVE (`script.Parent.Packages.signal`): the published archive re-roots at
-- this module's directory, so that path resolves identically at dev time and after a
-- consumer installs us - including when we are installed as a transitive dependency and live
-- inside a parent's Packages/ folder.

local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Packages.signal)
local Trove = require(script.Parent.Packages.trove)

local Machine = require(script.Parent.Machine)
local Queue = require(script.Parent.Queue)

-- The round machine resolves the full cascade on every tick, so its behaviour is identical
-- at 5 Hz and at 60 Hz. 5 Hz is plenty for phase timing a human perceives, and it keeps this
-- off the frame budget entirely.
local TICK_INTERVAL = 0.2

local RoundService = {}
RoundService.__index = RoundService

--[[
	No require-time side effects and none in the constructor either: building a service
	connects nothing. Call :Start() to begin ticking. That is what lets this participate in
	forge-lifecycle's Init/Start ordering instead of racing it.
]]
function RoundService.new(config: Machine.Config, clock: (() -> number)?)
	local self = setmetatable({}, RoundService)

	self._clock = clock or os.clock
	self._machine = Machine.new(config, self._clock())
	self._queue = Queue.new({ capacity = config.maxPlayers * 8 })
	self._config = config
	self._trove = Trove.new()
	self._objectiveMet = false
	self._participants = {} :: { [unknown]: true }
	self._participantCount = 0
	self._accumulator = 0

	-- Every signal goes in the trove, so :Destroy() cannot leave a dangling connection.
	self.PhaseChanged = self._trove:Construct(Signal)
	self.MatchStarted = self._trove:Construct(Signal)
	self.MatchEnded = self._trove:Construct(Signal)
	self.QueueChanged = self._trove:Construct(Signal)

	return self
end

function RoundService:Start(): ()
	assert(not self._started, "RoundService is already started")
	self._started = true

	self._trove:Connect(RunService.Heartbeat, function(delta: number)
		self._accumulator += delta
		if self._accumulator < TICK_INTERVAL then
			return
		end
		self._accumulator = 0
		self:_tick()
	end)
end

function RoundService:_tick(): ()
	local now = self._clock()
	local transitions = self._machine:Tick(now, {
		queued = self._queue:Size(),
		participants = self._participantCount,
		objectiveMet = self._objectiveMet,
	})

	for _, transition in transitions do
		-- Lock the roster at the moment the match actually starts, not when the countdown
		-- began: a player who queued during intermission should get in.
		if transition.to == "active" then
			local ids = self._queue:Take(self._config.maxPlayers)
			table.clear(self._participants)
			self._participantCount = 0
			for _, id in ids do
				self._participants[id] = true
				self._participantCount += 1
			end
			self._objectiveMet = false
			self.MatchStarted:Fire(self._machine:Round(), ids)
		elseif transition.to == "results" then
			self.MatchEnded:Fire(self._machine:Round(), transition.reason)
			table.clear(self._participants)
			self._participantCount = 0
			self._objectiveMet = false
		end

		self.PhaseChanged:Fire(transition)
	end
end

function RoundService:Join(id: unknown): boolean
	-- Already playing? Not a queue action. Silently ignoring is right: it is a UI event.
	if self._participants[id] then
		return false
	end
	local joined = self._queue:Join(id, self._clock())
	if joined then
		self.QueueChanged:Fire(self._queue:Size())
	end
	return joined
end

function RoundService:Leave(id: unknown): boolean
	local left = self._queue:Leave(id)
	if left then
		self.QueueChanged:Fire(self._queue:Size())
	end
	-- Leaving mid-match drops the participant count, which is what lets the machine abort
	-- a round that has emptied out.
	if self._participants[id] then
		self._participants[id] = nil
		self._participantCount -= 1
	end
	return left
end

--[[
	Report that the win condition is met. The machine picks it up on the next tick and ends
	the round with reason "objective-met" rather than "time-limit".
]]
function RoundService:SetObjectiveMet(met: boolean): ()
	self._objectiveMet = met
end

function RoundService:Phase(): Machine.Phase
	return self._machine:Phase()
end

function RoundService:Remaining(): number?
	return self._machine:Remaining(self._clock())
end

function RoundService:Round(): number
	return self._machine:Round()
end

function RoundService:QueueSize(): number
	return self._queue:Size()
end

function RoundService:LongestQueueWait(): number
	return self._queue:LongestWait(self._clock())
end

function RoundService:IsParticipant(id: unknown): boolean
	return self._participants[id] == true
end

function RoundService:Destroy(): ()
	self._trove:Destroy()
	self._started = false
end

return RoundService
