--!strict
-- FakeClock: a clock you drive by hand.
--
-- Every module in this workspace that cares about time takes its clock as an argument.
-- This is why: "the session lock goes stale after 30 seconds" becomes an instant assertion
-- instead of a 30-second test, and there is no flakiness from real wall-clock jitter.

export type FakeClock = {
	-- Pass this where a `() -> number` clock is expected.
	Now: () -> number,
	Advance: (seconds: number) -> number,
	Set: (seconds: number) -> (),
	-- Schedule a callback for `Advance` to fire when it passes that time. Enough for
	-- testing timers without a scheduler.
	Delay: (seconds: number, callback: () -> ()) -> (),
}

local FakeClock = {}

function FakeClock.new(start: number?): FakeClock
	local now = start or 0
	local pending: { { at: number, callback: () -> () } } = {}

	local function fire(upTo: number)
		-- Fire in time order, and re-check the list each pass: a callback may schedule
		-- another one, and it should still run if its time has already passed.
		while true do
			local nextIndex: number? = nil
			local nextAt = math.huge
			for index, entry in pending do
				if entry.at <= upTo and entry.at < nextAt then
					nextIndex, nextAt = index, entry.at
				end
			end
			if nextIndex == nil then
				break
			end
			local entry = table.remove(pending, nextIndex)
			if entry then
				entry.callback()
			end
		end
	end

	local self: FakeClock
	self = {
		Now = function()
			return now
		end,
		Advance = function(seconds)
			assert(seconds >= 0, "cannot advance backwards; use Set for that")
			now += seconds
			fire(now)
			return now
		end,
		-- Deliberately allows going backwards: a non-monotonic clock is a real
		-- condition worth testing against, not just a hypothetical.
		Set = function(seconds)
			now = seconds
			fire(now)
		end,
		Delay = function(seconds, callback)
			table.insert(pending, { at = now + seconds, callback = callback })
		end,
	}
	return self
end

return FakeClock
