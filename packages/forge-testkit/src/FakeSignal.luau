--!strict
-- FakeSignal: a minimal signal, enough to stand in for a RBXScriptSignal in a spec.
--
-- Not a replacement for sleitnick/signal in production code - take the mirror for that.
-- This exists so the other fakes (players, remotes) have events, with no dependency and
-- no Roblox API.

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type FakeSignal<T...> = {
	Connect: (self: FakeSignal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: FakeSignal<T...>, handler: (T...) -> ()) -> Connection,
	Fire: (self: FakeSignal<T...>, T...) -> (),
	DisconnectAll: (self: FakeSignal<T...>) -> (),
	Count: (self: FakeSignal<T...>) -> number,
}

local FakeSignal = {}
FakeSignal.__index = FakeSignal

function FakeSignal.new<T...>(): FakeSignal<T...>
	return (setmetatable({ _handlers = {} }, FakeSignal) :: any) :: FakeSignal<T...>
end

function FakeSignal.Connect<T...>(self: FakeSignal<T...>, handler: (T...) -> ()): Connection
	local this = self :: any
	local entry = { handler = handler, connected = true }
	table.insert(this._handlers, entry)

	local connection = {
		Connected = true,
		Disconnect = function(conn)
			entry.connected = false
			conn.Connected = false
			local index = table.find(this._handlers, entry)
			if index then
				table.remove(this._handlers, index)
			end
		end,
	}
	return connection :: any
end

function FakeSignal.Once<T...>(self: FakeSignal<T...>, handler: (T...) -> ()): Connection
	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function FakeSignal.Fire<T...>(self: FakeSignal<T...>, ...: any): ()
	-- Iterate a snapshot: a handler may disconnect itself or others mid-fire, and
	-- mutating the list we are walking would skip handlers.
	local snapshot = table.clone((self :: any)._handlers)
	for _, entry in snapshot do
		if entry.connected then
			entry.handler(...)
		end
	end
end

function FakeSignal.DisconnectAll<T...>(self: FakeSignal<T...>): ()
	local this = self :: any
	for _, entry in this._handlers do
		entry.connected = false
	end
	table.clear(this._handlers)
end

function FakeSignal.Count<T...>(self: FakeSignal<T...>): number
	return #(self :: any)._handlers
end

return FakeSignal
