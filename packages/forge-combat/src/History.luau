--!strict
-- History: a bounded per-entity ring buffer of timestamped positions, with interpolated
-- lookup at any past instant inside the retained window.
--
-- This is the substrate for lag compensation. The client says "I swung at time T aiming
-- here"; the server needs to know where everyone ACTUALLY was at time T according to its
-- own record, not according to the client. Without this you have two bad options: resolve
-- hits against current positions (which feels broken at any real ping, because you shot
-- where the target was, not where they are) or trust client-reported hits (which is a free
-- aimbot).
--
-- BOUNDED IS THE WHOLE POINT. The window caps how far back a claim may reach. Unbounded
-- rewind lets a client claim a hit on someone who moved away seconds ago; too short and
-- you punish players on bad connections for the network's behaviour. The bound lives here;
-- the policy for what to do at the edge lives in Claim.luau.
--
-- Pure Luau, injected clock, `{X, Y, Z}` samples - so the entire rewind mechanism is
-- testable in a terminal. This module is also why forge-sched was dropped: the fixed-step
-- buffer only ever mattered here.

export type Vec = { X: number, Y: number, Z: number }

export type Snapshot = {
	at: number,
	position: Vec,
}

export type Options = {
	-- How far back lookups may reach, in seconds. 0.25 is a reasonable default: it covers
	-- most real-world ping without letting a claim reach absurdly far into the past.
	windowSeconds: number,
	-- Expected samples per second. Only sizes the buffer; recording faster is fine, it
	-- just means the window fills sooner.
	sampleRate: number?,
}

local History = {}
History.__index = History

export type History = {
	Record: (self: History, id: unknown, position: Vec, at: number) -> (),
	SampleAt: (self: History, id: unknown, at: number) -> (Vec?, string?),
	Newest: (self: History, id: unknown) -> Snapshot?,
	Oldest: (self: History, id: unknown) -> Snapshot?,
	Span: (self: History, id: unknown) -> (number?, number?),
	Count: (self: History, id: unknown) -> number,
	Forget: (self: History, id: unknown) -> (),
	Entities: (self: History) -> number,
	WindowSeconds: (self: History) -> number,
}

local DEFAULT_SAMPLE_RATE = 20

function History.new(options: Options): History
	assert(options.windowSeconds > 0, "windowSeconds must be positive")
	local sampleRate = options.sampleRate or DEFAULT_SAMPLE_RATE
	assert(sampleRate > 0, "sampleRate must be positive")

	-- +2 so the buffer can still hold a sample on each side of the window edge after
	-- wrapping, which is what makes an interpolated lookup at the boundary possible.
	local capacity = math.max(2, math.ceil(options.windowSeconds * sampleRate) + 2)

	return (
		setmetatable({
			_window = options.windowSeconds,
			_capacity = capacity,
			-- id -> { samples: {Snapshot}, next: number, size: number }
			_buffers = {} :: { [unknown]: any },
		}, History) :: any
	) :: History
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Append a sample. `at` must be non-decreasing per entity - the caller owns the clock, and
	an out-of-order sample is silently dropped rather than corrupting the ordering that
	SampleAt's search depends on.
]]
function History.Record(self: History, id: unknown, position: Vec, at: number): ()
	local this = self :: any
	if not isFinite(at) then
		return
	end
	if not (isFinite(position.X) and isFinite(position.Y) and isFinite(position.Z)) then
		return
	end

	local buffer = this._buffers[id]
	if buffer == nil then
		buffer = { samples = table.create(this._capacity), next = 1, size = 0 }
		this._buffers[id] = buffer
	end

	-- Reject a sample older than the newest one we hold. Interpolation assumes ordering.
	local newest = History._newestRaw(this, buffer)
	if newest ~= nil and at < newest.at then
		return
	end

	buffer.samples[buffer.next] =
		{ at = at, position = { X = position.X, Y = position.Y, Z = position.Z } }
	buffer.next = (buffer.next % this._capacity) + 1
	buffer.size = math.min(buffer.size + 1, this._capacity)
end

function History._newestRaw(this: any, buffer: any): Snapshot?
	if buffer.size == 0 then
		return nil
	end
	local index = ((buffer.next - 2) % this._capacity) + 1
	return buffer.samples[index]
end

function History._oldestRaw(this: any, buffer: any): Snapshot?
	if buffer.size == 0 then
		return nil
	end
	if buffer.size < this._capacity then
		return buffer.samples[1]
	end
	return buffer.samples[buffer.next]
end

-- Ordered oldest-to-newest view. The buffer is small (a few dozen entries), so building a
-- list beats an index-arithmetic binary search for clarity, and the cost is irrelevant next
-- to a raycast.
function History._ordered(this: any, buffer: any): { Snapshot }
	local out = table.create(buffer.size)
	if buffer.size < this._capacity then
		for index = 1, buffer.size do
			table.insert(out, buffer.samples[index])
		end
	else
		for offset = 0, this._capacity - 1 do
			local index = ((buffer.next - 1 + offset) % this._capacity) + 1
			table.insert(out, buffer.samples[index])
		end
	end
	return out
end

--[[
	Where was `id` at time `at`?

	Returns a position, or `nil` plus a reason. The reasons are the interesting part, and a
	caller should treat them differently:

	  "unknown"  - we have no record of this entity at all.
	  "future"   - `at` is ahead of our newest sample. A client claiming the future is
	               either badly desynced or lying.
	  "expired"  - `at` is older than the retained window. THIS IS THE POLICY EDGE: it means
	               the claim MIGHT have been legitimate on a bad connection, and we simply
	               cannot verify it. Claim.luau decides what to do about that.

	Exact hits return that sample; anything between two samples is linearly interpolated.
	Linear rather than something smoother because we are reconstructing a few tens of
	milliseconds of travel, where the error is far below hitbox size, and a curve fitted
	through client-influenced samples would invent motion that never happened.
]]
function History.SampleAt(self: History, id: unknown, at: number): (Vec?, string?)
	local this = self :: any
	local buffer = this._buffers[id]
	if buffer == nil or buffer.size == 0 then
		return nil, "unknown"
	end
	if not isFinite(at) then
		return nil, "future"
	end

	local newest = History._newestRaw(this, buffer) :: Snapshot
	if at > newest.at then
		return nil, "future"
	end
	-- The window is measured back from our newest record, not from "now": that keeps the
	-- decision independent of when the caller happens to ask.
	if at < newest.at - this._window then
		return nil, "expired"
	end

	local ordered = History._ordered(this, buffer)
	local oldest = ordered[1]
	if at < oldest.at then
		-- Inside the window but before anything we retained (the entity only just
		-- appeared). Not verifiable, and not the client's fault - same edge as expired.
		return nil, "expired"
	end

	for index = 1, #ordered - 1 do
		local a, b = ordered[index], ordered[index + 1]
		if at >= a.at and at <= b.at then
			local span = b.at - a.at
			if span <= 0 then
				return a.position
			end
			local alpha = (at - a.at) / span
			return {
				X = a.position.X + (b.position.X - a.position.X) * alpha,
				Y = a.position.Y + (b.position.Y - a.position.Y) * alpha,
				Z = a.position.Z + (b.position.Z - a.position.Z) * alpha,
			}
		end
	end

	return newest.position
end

function History.Newest(self: History, id: unknown): Snapshot?
	local this = self :: any
	local buffer = this._buffers[id]
	return if buffer then History._newestRaw(this, buffer) else nil
end

function History.Oldest(self: History, id: unknown): Snapshot?
	local this = self :: any
	local buffer = this._buffers[id]
	return if buffer then History._oldestRaw(this, buffer) else nil
end

--[[ The retained time span for an entity, as (oldest, newest). ]]
function History.Span(self: History, id: unknown): (number?, number?)
	local oldest = self:Oldest(id)
	local newest = self:Newest(id)
	if oldest == nil or newest == nil then
		return nil, nil
	end
	return oldest.at, newest.at
end

function History.Count(self: History, id: unknown): number
	local buffer = (self :: any)._buffers[id]
	return if buffer then buffer.size else 0
end

--[[ Drop an entity. Call from PlayerRemoving and on character death. ]]
function History.Forget(self: History, id: unknown): ()
	(self :: any)._buffers[id] = nil
end

function History.Entities(self: History): number
	local count = 0
	for _ in (self :: any)._buffers do
		count += 1
	end
	return count
end

function History.WindowSeconds(self: History): number
	return (self :: any)._window
end

return History
