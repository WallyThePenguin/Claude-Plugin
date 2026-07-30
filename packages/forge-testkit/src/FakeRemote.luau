--!strict
-- FakeRemote: RemoteEvent and RemoteFunction stand-ins.
--
-- This is what makes remote-handling code testable at all. Every hostile case that matters
-- - wrong arity, wrong types, NaN, a flood of calls, a client impersonating another player
-- - is trivial to express here and impossible to express in Studio without an exploit
-- client.
--
-- Note `FireServer` takes the player explicitly. The real engine injects the sender and a
-- client cannot forge it, but in a spec you WANT to send as whoever you like: "player B
-- claims to be acting on player A's inventory" is a test case, not a bug in the fake.

local FakeSignal = require("./FakeSignal")

export type FakeRemoteEvent = {
	OnServerEvent: any,
	OnClientEvent: any,
	-- Client -> server. `player` is who the server will see as the sender.
	FireServer: (self: FakeRemoteEvent, player: any, ...any) -> (),
	FireClient: (self: FakeRemoteEvent, player: any, ...any) -> (),
	FireAllClients: (self: FakeRemoteEvent, ...any) -> (),
	-- Test inspection: every server -> client send, in order.
	Sent: (self: FakeRemoteEvent) -> { { player: any, args: { any } } },
	ClearSent: (self: FakeRemoteEvent) -> (),
}

export type FakeRemoteFunction = {
	OnServerInvoke: ((player: any, ...any) -> ...any)?,
	InvokeServer: (self: FakeRemoteFunction, player: any, ...any) -> ...any,
	[any]: any,
}

local FakeRemote = {}

local RemoteEvent = {}
RemoteEvent.__index = RemoteEvent

function FakeRemote.event(): FakeRemoteEvent
	return (
		setmetatable({
			OnServerEvent = FakeSignal.new(),
			OnClientEvent = FakeSignal.new(),
			_sent = {},
		}, RemoteEvent) :: any
	) :: FakeRemoteEvent
end

function RemoteEvent.FireServer(self: any, player: any, ...: any): ()
	self.OnServerEvent:Fire(player, ...)
end

function RemoteEvent.FireClient(self: any, player: any, ...: any): ()
	table.insert(self._sent, { player = player, args = table.pack(...) })
	self.OnClientEvent:Fire(...)
end

function RemoteEvent.FireAllClients(self: any, ...: any): ()
	table.insert(self._sent, { player = "all", args = table.pack(...) })
	self.OnClientEvent:Fire(...)
end

function RemoteEvent.Sent(self: any)
	return table.clone(self._sent)
end

function RemoteEvent.ClearSent(self: any): ()
	table.clear(self._sent)
end

local RemoteFunction = {}
RemoteFunction.__index = RemoteFunction

function FakeRemote.func(): FakeRemoteFunction
	return (setmetatable({ OnServerInvoke = nil }, RemoteFunction) :: any) :: FakeRemoteFunction
end

--[[
	Invoke as `player`. Errors if nothing is bound, which mirrors the real behaviour and
	catches a handler that was never registered - a failure mode that otherwise shows up
	as a mysterious client-side hang.
]]
function RemoteFunction.InvokeServer(self: any, player: any, ...: any): ...any
	local handler = self.OnServerInvoke
	if handler == nil then
		error("OnServerInvoke is not bound", 2)
	end
	return handler(player, ...)
end

return FakeRemote
