--!strict
-- FakeDataStore: an in-memory GlobalDataStore stand-in that can be made to misbehave.
--
-- The point is NOT to test the happy path - that always works. It is to test the paths
-- that only happen in production: a call that fails three times then succeeds, two servers
-- racing for the same key, a budget that has run out, a value written by a newer schema.
-- Those are exactly the paths that cause data loss, and they are impossible to trigger
-- reliably against the real service.
--
-- Deliberately synchronous. Real DataStore calls yield, and a spec that has to await is
-- harder to reason about; what we are testing is the DECISION LOGIC around the call, and
-- that logic is the same either way. Where yield-ordering itself is the thing under test,
-- use `failFor`/`Latency` plus FakeClock to sequence it explicitly.

local FakeDataStore = {}
FakeDataStore.__index = FakeDataStore

export type Call = {
	method: string,
	key: string,
	ok: boolean,
}

export type FakeDataStore = {
	GetAsync: (self: FakeDataStore, key: string) -> any,
	SetAsync: (self: FakeDataStore, key: string, value: any) -> (),
	UpdateAsync: (self: FakeDataStore, key: string, transform: (any) -> any) -> any,
	RemoveAsync: (self: FakeDataStore, key: string) -> any,
	IncrementAsync: (self: FakeDataStore, key: string, delta: number) -> number,

	-- Test controls.
	Seed: (self: FakeDataStore, key: string, value: any) -> (),
	Peek: (self: FakeDataStore, key: string) -> any,
	FailNext: (self: FakeDataStore, count: number, message: string?) -> (),
	FailAlways: (self: FakeDataStore, message: string?) -> (),
	StopFailing: (self: FakeDataStore) -> (),
	Calls: (self: FakeDataStore) -> { Call },
	CallCount: (self: FakeDataStore, method: string?) -> number,
	Reset: (self: FakeDataStore) -> (),
}

function FakeDataStore.new(): FakeDataStore
	return (
		setmetatable({
			_store = {} :: { [string]: any },
			_calls = {} :: { Call },
			_failuresLeft = 0,
			_failAlways = false,
			_failMessage = "DataStore request failed",
		}, FakeDataStore) :: any
	) :: FakeDataStore
end

function FakeDataStore._record(self: any, method: string, key: string, ok: boolean)
	table.insert(self._calls, { method = method, key = key, ok = ok })
end

-- Every method funnels through here so failure injection applies uniformly.
function FakeDataStore._guard(self: any, method: string, key: string)
	if self._failAlways or self._failuresLeft > 0 then
		if self._failuresLeft > 0 then
			self._failuresLeft -= 1
		end
		self:_record(method, key, false)
		error(self._failMessage, 0)
	end
	self:_record(method, key, true)
end

-- Deep copy on the way in and out. The real service serialises, so a caller cannot hold a
-- live reference to stored data - and a fake that hands back the same table hides bugs
-- where production code mutates what it thinks is a private copy.
local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, entry in value do
		copy[deepCopy(key)] = deepCopy(entry)
	end
	return copy
end

function FakeDataStore.GetAsync(self: FakeDataStore, key: string): any
	local this = self :: any
	this:_guard("GetAsync", key)
	return deepCopy(this._store[key])
end

function FakeDataStore.SetAsync(self: FakeDataStore, key: string, value: any): ()
	local this = self :: any
	this:_guard("SetAsync", key)
	this._store[key] = deepCopy(value)
end

--[[
	The method production code should actually be using. The transform sees the current
	value and returns the new one; returning nil aborts the write, matching the real API.
]]
function FakeDataStore.UpdateAsync(self: FakeDataStore, key: string, transform: (any) -> any): any
	local this = self :: any
	this:_guard("UpdateAsync", key)
	local current = deepCopy(this._store[key])
	local updated = transform(current)
	if updated == nil then
		return nil
	end
	this._store[key] = deepCopy(updated)
	return deepCopy(updated)
end

function FakeDataStore.RemoveAsync(self: FakeDataStore, key: string): any
	local this = self :: any
	this:_guard("RemoveAsync", key)
	local previous = deepCopy(this._store[key])
	this._store[key] = nil
	return previous
end

function FakeDataStore.IncrementAsync(self: FakeDataStore, key: string, delta: number): number
	local this = self :: any
	this:_guard("IncrementAsync", key)
	local updated = (this._store[key] or 0) + delta
	this._store[key] = updated
	return updated
end

--[[
	Put a value in place without recording a call. Use this for fixtures - especially
	old-schema data, which is the only honest way to test a migration chain.
]]
function FakeDataStore.Seed(self: FakeDataStore, key: string, value: any): ()
	(self :: any)._store[key] = deepCopy(value)
end

--[[ Read without recording a call, for assertions. ]]
function FakeDataStore.Peek(self: FakeDataStore, key: string): any
	return deepCopy((self :: any)._store[key])
end

--[[
	Make the next `count` calls throw. This is how you test retry-with-backoff: fail
	twice, then let it through, and assert the caller recovered.
]]
function FakeDataStore.FailNext(self: FakeDataStore, count: number, message: string?): ()
	local this = self :: any
	this._failuresLeft = count
	if message then
		this._failMessage = message
	end
end

--[[ Fail everything - for testing the give-up path. ]]
function FakeDataStore.FailAlways(self: FakeDataStore, message: string?): ()
	local this = self :: any
	this._failAlways = true
	if message then
		this._failMessage = message
	end
end

function FakeDataStore.StopFailing(self: FakeDataStore): ()
	local this = self :: any
	this._failAlways = false
	this._failuresLeft = 0
end

--[[
	Every call made, in order, with whether it succeeded. Assert on this to catch the
	quiet failures: a save that never happened, or a GetAsync+SetAsync pair where an
	UpdateAsync belonged.
]]
function FakeDataStore.Calls(self: FakeDataStore): { Call }
	return table.clone((self :: any)._calls)
end

function FakeDataStore.CallCount(self: FakeDataStore, method: string?): number
	local count = 0
	for _, call in (self :: any)._calls do
		if method == nil or call.method == method then
			count += 1
		end
	end
	return count
end

function FakeDataStore.Reset(self: FakeDataStore): ()
	local this = self :: any
	table.clear(this._store)
	table.clear(this._calls)
	this:StopFailing()
end

return FakeDataStore
