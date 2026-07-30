--!strict
-- AbuseScore: weighted, decaying suspicion per key.
--
-- The reason this exists rather than a plain counter: on Roblox almost every individual
-- signal is ambiguous. One impossible speed sample is lag. One rejected remote is a
-- dropped packet. Acting on a single observation produces false positives and punishes
-- players on bad connections - which is worse than missing a cheater, because the
-- cheater will come back and the wrongly-kicked player will not.
--
-- So: treat each violation as EVIDENCE with a weight, decay it over time so old evidence
-- stops counting, and act on the accumulated score. A cheat produces a sustained pattern;
-- lag produces isolated spikes that decay away.
--
-- Pure Luau; the clock is injected.

export type Options = {
	-- Score at or above which Exceeded() reports true.
	threshold: number,
	-- Points shed per second. Pick it against how long a pattern must persist:
	-- decay 1/s with threshold 10 means ~10 points must land inside ~10 seconds.
	decayPerSecond: number,
	-- Ceiling, so a burst cannot bank an unpayable debt that keeps a player flagged
	-- long after they stopped. Defaults to 3x threshold.
	maxScore: number?,
	idleTimeout: number?,
}

type Entry = {
	score: number,
	lastUpdate: number,
	-- Kind -> times seen. What you actually want in a report: "score 14" tells you
	-- nothing, "11 speed + 3 reach" tells you what they were doing.
	counts: { [string]: number },
}

export type AbuseScore = {
	Report: (self: AbuseScore, key: unknown, kind: string, weight: number?) -> number,
	Score: (self: AbuseScore, key: unknown) -> number,
	Exceeded: (self: AbuseScore, key: unknown) -> boolean,
	Breakdown: (self: AbuseScore, key: unknown) -> { [string]: number },
	Forget: (self: AbuseScore, key: unknown) -> (),
	Prune: (self: AbuseScore) -> number,
}

local AbuseScore = {}
AbuseScore.__index = AbuseScore

function AbuseScore.new(options: Options, clock: () -> number): AbuseScore
	assert(options.threshold > 0, "threshold must be positive")
	assert(options.decayPerSecond >= 0, "decayPerSecond must not be negative")

	return (
		setmetatable({
			_threshold = options.threshold,
			_decay = options.decayPerSecond,
			_maxScore = options.maxScore or options.threshold * 3,
			_idleTimeout = options.idleTimeout or 600,
			_clock = clock,
			_entries = {} :: { [unknown]: Entry },
		}, AbuseScore) :: any
	) :: AbuseScore
end

function AbuseScore._decayed(self: any, key: unknown): Entry
	local entry = self._entries[key]
	local now = self._clock()
	if entry == nil then
		entry = { score = 0, lastUpdate = now, counts = {} }
		self._entries[key] = entry
		return entry
	end
	local elapsed = now - entry.lastUpdate
	if elapsed > 0 then
		entry.score = math.max(0, entry.score - elapsed * self._decay)
	end
	entry.lastUpdate = now
	return entry
end

--[[
	Record one violation. Returns the score after it lands.

	`kind` is a stable string ("speed", "reach", "rate", "teleport"). `weight` defaults
	to 1; weight the confident signals higher - "claimed a hit 4 studs out of range" is
	worth more than "moved slightly fast for one sample".
]]
function AbuseScore.Report(self: AbuseScore, key: unknown, kind: string, weight: number?): number
	local this = self :: any
	local entry = this:_decayed(key)
	entry.score = math.min(this._maxScore, entry.score + (weight or 1))
	entry.counts[kind] = (entry.counts[kind] or 0) + 1
	return entry.score
end

function AbuseScore.Score(self: AbuseScore, key: unknown): number
	local this = self :: any
	if this._entries[key] == nil then
		return 0
	end
	return this:_decayed(key).score
end

function AbuseScore.Exceeded(self: AbuseScore, key: unknown): boolean
	return (self :: any):Score(key) >= (self :: any)._threshold
end

function AbuseScore.Breakdown(self: AbuseScore, key: unknown): { [string]: number }
	local entry = (self :: any)._entries[key]
	if entry == nil then
		return {}
	end
	return table.clone(entry.counts)
end

function AbuseScore.Forget(self: AbuseScore, key: unknown): ()
	(self :: any)._entries[key] = nil
end

function AbuseScore.Prune(self: AbuseScore): number
	local this = self :: any
	local now = this._clock()
	local removed = 0
	for key, entry in this._entries do
		if now - entry.lastUpdate > this._idleTimeout then
			this._entries[key] = nil
			removed += 1
		end
	end
	return removed
end

return AbuseScore
