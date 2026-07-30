--!strict
-- Queue: the matchmaking queue.
--
-- Fair by wait time, which is the only fairness property a small-scale arena needs and the
-- one players notice immediately when it is missing. No skill rating: with a handful of
-- concurrent players, rating-based matching just makes everyone wait longer for a worse
-- match. Add it when population justifies it, not before.
--
-- Pure Luau, injected clock - so "this player has waited 90 seconds" is an assertion, not
-- a 90-second test.

export type Entry = {
	id: unknown,
	joinedAt: number,
}

export type Options = {
	-- Hard cap. Beyond this, Join refuses rather than growing without bound - an
	-- unbounded queue is a memory target.
	capacity: number?,
}

local DEFAULT_CAPACITY = 200

local Queue = {}
Queue.__index = Queue

export type Queue = {
	Join: (self: Queue, id: unknown, now: number) -> boolean,
	Leave: (self: Queue, id: unknown) -> boolean,
	Contains: (self: Queue, id: unknown) -> boolean,
	Size: (self: Queue) -> number,
	WaitedFor: (self: Queue, id: unknown, now: number) -> number?,
	LongestWait: (self: Queue, now: number) -> number,
	Take: (self: Queue, count: number) -> { unknown },
	Peek: (self: Queue, count: number) -> { unknown },
	Clear: (self: Queue) -> (),
}

function Queue.new(options: Options?): Queue
	local opts: Options = options or {}
	local capacity = opts.capacity or DEFAULT_CAPACITY
	assert(capacity >= 1, "capacity must be at least 1")

	return (
		setmetatable({
			_capacity = capacity,
			-- Ordered oldest-first. Small enough that a table beats a heap, and staying
			-- an array keeps ordering obvious at a glance.
			_entries = {} :: { Entry },
			-- id -> true, so Contains and duplicate-Join are O(1).
			_present = {} :: { [unknown]: true },
		}, Queue) :: any
	) :: Queue
end

--[[
	Add a player. Returns false if they are already queued or the queue is full.

	Joining twice is a no-op rather than an error: a double-click on the queue button is a
	UI event, not an exploit, and it must not reset the player's place in line.
]]
function Queue.Join(self: Queue, id: unknown, now: number): boolean
	local this = self :: any
	if this._present[id] then
		return false
	end
	if #this._entries >= this._capacity then
		return false
	end
	this._present[id] = true
	table.insert(this._entries, { id = id, joinedAt = now })
	return true
end

--[[ Remove a player. Returns whether they were there. Idempotent. ]]
function Queue.Leave(self: Queue, id: unknown): boolean
	local this = self :: any
	if not this._present[id] then
		return false
	end
	this._present[id] = nil
	for index, entry in this._entries do
		if entry.id == id then
			table.remove(this._entries, index)
			break
		end
	end
	return true
end

function Queue.Contains(self: Queue, id: unknown): boolean
	return (self :: any)._present[id] == true
end

function Queue.Size(self: Queue): number
	return #(self :: any)._entries
end

function Queue.WaitedFor(self: Queue, id: unknown, now: number): number?
	for _, entry in (self :: any)._entries do
		if entry.id == id then
			return math.max(0, now - entry.joinedAt)
		end
	end
	return nil
end

--[[
	Longest wait in the queue, or 0 when empty. This is the number to surface and alarm on:
	average wait hides the player who has been waiting four minutes, and that player is the
	one who leaves.
]]
function Queue.LongestWait(self: Queue, now: number): number
	local this = self :: any
	local oldest = this._entries[1]
	if oldest == nil then
		return 0
	end
	return math.max(0, now - oldest.joinedAt)
end

--[[
	Pop up to `count` players, longest-waiting first, and return their ids.

	Takes fewer than asked rather than refusing, so the caller decides whether a short match
	is acceptable - that policy belongs to the round machine's minPlayers, not here.
]]
function Queue.Take(self: Queue, count: number): { unknown }
	local this = self :: any
	local taken = {}
	for _ = 1, math.min(count, #this._entries) do
		local entry = table.remove(this._entries, 1) :: Entry
		this._present[entry.id] = nil
		table.insert(taken, entry.id)
	end
	return taken
end

--[[ Who WOULD be taken, without removing them. For lobby UI and for tests. ]]
function Queue.Peek(self: Queue, count: number): { unknown }
	local this = self :: any
	local out = {}
	for index = 1, math.min(count, #this._entries) do
		table.insert(out, this._entries[index].id)
	end
	return out
end

function Queue.Clear(self: Queue): ()
	local this = self :: any
	table.clear(this._entries)
	table.clear(this._present)
end

return Queue
