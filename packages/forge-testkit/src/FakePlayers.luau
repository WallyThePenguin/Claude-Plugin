--!strict
-- FakePlayers: a Players service stand-in, plus the minimum of a Player object.
--
-- Enough to test the code that actually causes production bugs: per-player state that
-- never gets cleaned up on PlayerRemoving (a leak AND a denial-of-service surface), and
-- logic that assumes a player is still present after a yield.

local FakeSignal = require("./FakeSignal")

export type FakePlayer = {
	Name: string,
	UserId: number,
	Character: any,
	Kick: (self: FakePlayer, reason: string?) -> (),
	-- Test inspection: every kick reason this player received.
	KickReasons: { string },
	[any]: any,
}

export type FakePlayers = {
	PlayerAdded: any,
	PlayerRemoving: any,
	GetPlayers: (self: FakePlayers) -> { FakePlayer },
	GetPlayerByUserId: (self: FakePlayers, userId: number) -> FakePlayer?,
	-- Test controls.
	Add: (self: FakePlayers, name: string, userId: number?) -> FakePlayer,
	Remove: (self: FakePlayers, player: FakePlayer) -> (),
	Count: (self: FakePlayers) -> number,
}

local FakePlayers = {}
FakePlayers.__index = FakePlayers

local nextUserId = 1

function FakePlayers.new(): FakePlayers
	return (
		setmetatable({
			PlayerAdded = FakeSignal.new(),
			PlayerRemoving = FakeSignal.new(),
			_players = {} :: { FakePlayer },
		}, FakePlayers) :: any
	) :: FakePlayers
end

--[[ Add a player and fire PlayerAdded. ]]
function FakePlayers.Add(self: FakePlayers, name: string, userId: number?): FakePlayer
	local this = self :: any
	local id = userId
	if id == nil then
		id = nextUserId
		nextUserId += 1
	end

	local player: FakePlayer
	player = {
		Name = name,
		UserId = id :: number,
		Character = nil,
		KickReasons = {},
		Kick = function(selfPlayer, reason)
			table.insert(selfPlayer.KickReasons, reason or "")
		end,
	}

	table.insert(this._players, player)
	this.PlayerAdded:Fire(player)
	return player
end

--[[
	Fire PlayerRemoving and drop the player. Note the order: the signal fires while the
	player is still in GetPlayers, matching the real service - handlers that iterate
	players during removal see them.
]]
function FakePlayers.Remove(self: FakePlayers, player: FakePlayer): ()
	local this = self :: any
	local index = table.find(this._players, player)
	if index == nil then
		return
	end
	this.PlayerRemoving:Fire(player)
	table.remove(this._players, index)
end

function FakePlayers.GetPlayers(self: FakePlayers): { FakePlayer }
	return table.clone((self :: any)._players)
end

function FakePlayers.GetPlayerByUserId(self: FakePlayers, userId: number): FakePlayer?
	for _, player in (self :: any)._players do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

function FakePlayers.Count(self: FakePlayers): number
	return #(self :: any)._players
end

return FakePlayers
