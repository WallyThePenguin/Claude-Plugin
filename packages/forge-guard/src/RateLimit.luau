--!strict
-- RateLimit: per-key token buckets.
--
-- A perfectly valid remote call at 500 Hz is an attack. Validation cannot see it - every
-- individual call is well-formed - so rate is a separate axis and every remote needs a
-- budget on it.
--
-- Pure Luau: the clock is INJECTED, which is what makes "the bucket refills after 3
-- seconds" a one-line test instead of a 3-second one.
--
-- Token bucket rather than a fixed window, deliberately. A fixed window (N calls per
-- second, counter reset on the boundary) allows 2N calls across a boundary and produces
-- false positives for a player who legitimately bursts. A bucket refills continuously and
-- states the burst allowance explicitly.

export type Options = {
	-- Sustained rate, in tokens per second.
	rate: number,
	-- Bucket capacity: the largest burst tolerated after an idle period. Defaults to
	-- one second's worth, which is usually the honest answer.
	burst: number?,
	-- Seconds a key may sit untouched before it is dropped. Prevents unbounded growth
	-- from an attacker cycling keys. Defaults to 300.
	idleTimeout: number?,
}

type Bucket = {
	tokens: number,
	lastRefill: number,
	-- Cumulative rejections. This is the number that matters: a single rejection is
	-- lag, a rising count is a cheat.
	rejections: number,
}

export type RateLimit = {
	Consume: (self: RateLimit, key: unknown, cost: number?) -> boolean,
	Rejections: (self: RateLimit, key: unknown) -> number,
	Forget: (self: RateLimit, key: unknown) -> (),
	Prune: (self: RateLimit) -> number,
	Count: (self: RateLimit) -> number,
}

local RateLimit = {}
RateLimit.__index = RateLimit

--[[
	clock must be monotonic and in seconds. In Roblox pass `os.clock` or `time`; in a
	spec pass a closure over a variable you control.
]]
function RateLimit.new(options: Options, clock: () -> number): RateLimit
	assert(options.rate > 0, "rate must be positive")
	local burst = options.burst or options.rate
	assert(burst > 0, "burst must be positive")

	return (
		setmetatable({
			_rate = options.rate,
			_burst = burst,
			_idleTimeout = options.idleTimeout or 300,
			_clock = clock,
			_buckets = {} :: { [unknown]: Bucket },
		}, RateLimit) :: any
	) :: RateLimit
end

function RateLimit._bucket(self: any, key: unknown): Bucket
	local bucket = self._buckets[key]
	if bucket == nil then
		bucket = { tokens = self._burst, lastRefill = self._clock(), rejections = 0 }
		self._buckets[key] = bucket
	end
	return bucket
end

--[[
	Take `cost` tokens (default 1). Returns true if the call is within budget.

	A rejection is silent by design: the caller drops the request. Telling the client
	"you are rate limited" hands an attacker a tuning signal.
]]
function RateLimit.Consume(self: RateLimit, key: unknown, cost: number?): boolean
	local this = self :: any
	local amount = cost or 1
	local bucket = this:_bucket(key)
	local now = this._clock()

	-- Refill for elapsed time. Guard against a non-monotonic clock: if `now` went
	-- backwards, treat the interval as zero rather than draining the bucket.
	local elapsed = now - bucket.lastRefill
	if elapsed > 0 then
		bucket.tokens = math.min(this._burst, bucket.tokens + elapsed * this._rate)
		bucket.lastRefill = now
	elseif elapsed < 0 then
		bucket.lastRefill = now
	end

	if bucket.tokens >= amount then
		bucket.tokens -= amount
		return true
	end

	bucket.rejections += 1
	return false
end

function RateLimit.Rejections(self: RateLimit, key: unknown): number
	local bucket = (self :: any)._buckets[key]
	return if bucket then bucket.rejections else 0
end

--[[
	Drop a key's bucket. Call this from PlayerRemoving - a per-player table with no
	cleanup is both a memory leak and its own denial-of-service surface.
]]
function RateLimit.Forget(self: RateLimit, key: unknown): ()
	(self :: any)._buckets[key] = nil
end

--[[
	Drop every bucket untouched for longer than idleTimeout. Returns how many went.
	Safety net for keys that never get an explicit Forget.
]]
function RateLimit.Prune(self: RateLimit): number
	local this = self :: any
	local now = this._clock()
	local removed = 0
	for key, bucket in this._buckets do
		if now - bucket.lastRefill > this._idleTimeout then
			this._buckets[key] = nil
			removed += 1
		end
	end
	return removed
end

function RateLimit.Count(self: RateLimit): number
	local count = 0
	for _ in (self :: any)._buckets do
		count += 1
	end
	return count
end

return RateLimit
