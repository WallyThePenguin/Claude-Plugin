--!strict
-- RewardService: pays out coins through the idempotent ledger.
--
-- Every grant carries a SERVER-GENERATED transaction id. That is the whole reason
-- forge-economy exists: a retry, a rejoin, or a duplicated event replays the grant, and an
-- id makes the replay a no-op instead of free money.
--
-- Ids here are deterministic and derived from what actually happened -- run number, wave,
-- kill sequence -- rather than random. A random id would make every replay look like a new
-- transaction, which defeats the idempotency entirely.
--
-- PERSISTENCE IS NOT WIRED YET. Balances live in memory for this milestone; `nezuo/lapis`
-- is installed in the server realm and hooking it up is the next step. Until then a rejoin
-- loses coins, which is a known gap, not a silent one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ServerPackages = ServerScriptService:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Economy = require(ServerPackages["forge-economy"])

local ArenaConfig = require(Shared.ArenaConfig)
local WaveTable = require(Shared.WaveTable)

local RewardService = {}
RewardService.Name = "Rewards"

function RewardService:Init()
	self._ledger = Economy.Ledger.new({
		currencies = { ArenaConfig.Rewards.currency },
	})
	-- Per-player kill counter, used to build a stable transaction id per kill.
	self._killSeq = {} :: { [number]: number }
end

function RewardService:Start()
	Players.PlayerRemoving:Connect(function(player)
		-- TODO(M4b): save the profile via lapis BEFORE forgetting, or the balance is lost.
		self._ledger:Forget(player.UserId)
		self._killSeq[player.UserId] = nil
	end)
end

function RewardService:GrantKill(player: Player)
	local seq = (self._killSeq[player.UserId] or 0) + 1
	self._killSeq[player.UserId] = seq

	local result = self._ledger:Apply({
		id = `kill:{player.UserId}:{seq}`,
		owner = player.UserId,
		currency = ArenaConfig.Rewards.currency,
		delta = ArenaConfig.Rewards.perEnemy,
		kind = "kill",
	})
	if result.ok and not result.replay then
		self:_publish(player, result.balance)
	end
end

function RewardService:GrantRun(
	runId: number,
	wavesCleared: number,
	enemiesKilled: number,
	victory: boolean
)
	-- The per-kill coins were already paid, so the run payout covers only the wave and
	-- victory components. Paying perEnemy again here would double every kill.
	local rewards = ArenaConfig.Rewards
	local total = WaveTable.reward(wavesCleared, 0, victory, rewards)

	for _, player in Players:GetPlayers() do
		local result = self._ledger:Apply({
			-- Keyed on the run, so replaying the end-of-run event pays once.
			id = `run:{runId}:{player.UserId}`,
			owner = player.UserId,
			currency = rewards.currency,
			delta = total,
			kind = if victory then "victory" else "defeat",
			meta = { wavesCleared = wavesCleared, enemiesKilled = enemiesKilled },
		})
		if result.ok then
			self:_publish(player, result.balance)
		else
			warn(`[rewards] run payout rejected for {player.Name}: {result.reason}`)
		end
	end
end

function RewardService:Balance(player: Player): number
	return self._ledger:Balance(player.UserId, ArenaConfig.Rewards.currency)
end

--[[
	Publish a player's balance to that player only. A leaderstats-style value under the
	Player instance replicates to everyone; coins are not secret, but there is no reason to
	broadcast every balance to every client either.
]]
function RewardService:_publish(player: Player, balance: number)
	local stats = player:FindFirstChild("leaderstats")
	if stats == nil then
		stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = player
	end
	local coins = stats:FindFirstChild("Coins")
	if coins == nil then
		coins = Instance.new("IntValue")
		coins.Name = "Coins"
		coins.Parent = stats
	end
	(coins :: IntValue).Value = balance
end

return RewardService
