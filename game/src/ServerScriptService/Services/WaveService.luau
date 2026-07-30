--!strict
-- WaveService: spawns waves, tracks the run, and tells the round machine when it is won.
--
-- The lifecycle itself belongs to forge-round; this service only answers one question for
-- it -- "is the objective met?" -- and owns everything PvE-specific: what spawns, how much
-- of it, and what the run is worth.
--
-- The difficulty curve is NOT here. It is in WaveTable, which is pure and specced (19
-- assertions against the real shipped numbers). This file is the Roblox half: instances,
-- spawning, and cleanup.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local ServerPackages = ServerScriptService:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Round = require(ServerPackages["forge-round"])

local ArenaConfig = require(Shared.ArenaConfig)
local CombatPolicy = require(Shared.CombatPolicy)
local WaveTable = require(Shared.WaveTable)

local WaveService = {}
WaveService.Name = "Waves"
WaveService.Requires = { "Combat" }

function WaveService:Init(registry)
	self._registry = registry
	self._combat = registry:Get("Combat")
	self._clock = os.clock

	self._round = Round.Service.new(ArenaConfig.Round, self._clock)

	self._live = {} :: { [string]: Model }
	self._liveCount = 0
	self._nextEntityId = 0

	self._wave = 0
	self._wavesCleared = 0
	self._enemiesKilled = 0
	self._runActive = false
	self._spawning = false
end

function WaveService:Start()
	self._round.MatchStarted:Connect(function(runId, playerIds)
		self:_beginRun(runId, playerIds)
	end)

	self._round.MatchEnded:Connect(function(runId, reason)
		self:_endRun(runId, reason)
	end)

	self._round.PhaseChanged:Connect(function(transition)
		self:_replicate()
		print(`[forge] {transition.from} -> {transition.to} ({transition.reason})`)
	end)

	-- PvE: everyone present is in the run. There is no lobby to opt into, so joining the
	-- game IS joining the queue.
	Players.PlayerAdded:Connect(function(player)
		self._round:Join(player.UserId)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self._round:Leave(player.UserId)
	end)
	for _, player in Players:GetPlayers() do
		self._round:Join(player.UserId)
	end

	-- Enemies need position history too, or a hit on a moving one resolves against nothing.
	local accumulator = 0
	local interval = 1 / CombatPolicy.SampleRate
	RunService.Heartbeat:Connect(function(delta)
		accumulator += delta
		if accumulator < interval then
			return
		end
		accumulator = 0
		for id, model in self._live do
			local root = model:FindFirstChild("HumanoidRootPart")
			if root then
				self._combat:RecordEntity(id, (root :: BasePart).Position)
			end
		end
	end)

	self._round:Start()
end

function WaveService:_beginRun(runId: number, playerIds: { unknown })
	self._wave = 0
	self._wavesCleared = 0
	self._enemiesKilled = 0
	self._runActive = true

	-- Give everyone a weapon. Loadout selection is M5; for now the arena is playable.
	for _, userId in playerIds do
		local player = Players:GetPlayerByUserId(userId :: number)
		if player then
			self._combat:SetEquipped(player, "ember-falchion")
		end
	end

	task.spawn(function()
		self:_runWaves(runId)
	end)
end

function WaveService:_runWaves(runId: number)
	for wave = 1, ArenaConfig.Waves.count do
		-- A run can end under us -- everyone left, or the hard time limit hit. Bail rather
		-- than spawning into a finished match.
		if not self._runActive or self._round:Round() ~= runId then
			return
		end

		self._wave = wave
		local composition = WaveTable.compose(wave, ArenaConfig.Waves)
		self:_replicate()
		print(
			`[forge] wave {wave}/{ArenaConfig.Waves.count}: {composition.count} enemies, {composition.health} hp{if composition.elite
				then " (ELITE)"
				else ""}`
		)

		self:_spawnWave(composition)

		-- Wait for the wave to clear, re-checking the run is still ours each pass.
		while self._liveCount > 0 and self._runActive and self._round:Round() == runId do
			task.wait(0.25)
		end
		if not self._runActive or self._round:Round() ~= runId then
			return
		end

		self._wavesCleared = wave
		self:_replicate()

		if wave < ArenaConfig.Waves.count then
			task.wait(ArenaConfig.Waves.breatherSeconds)
		end
	end

	-- Every wave cleared: this is the win condition the round machine is waiting on.
	if self._runActive and self._round:Round() == runId then
		self._round:SetObjectiveMet(true)
	end
end

function WaveService:_spawnWave(composition)
	local template = ServerStorage:FindFirstChild("ForgeEnemyTemplate")
	if template == nil then
		warn("[forge] ServerStorage.ForgeEnemyTemplate is missing -- cannot spawn")
		return
	end

	local remaining = composition.count
	local rotation = composition.wave * 0.7 -- vary the ring so spawns do not read as scripted

	while remaining > 0 do
		local batch = math.min(remaining, composition.concurrent - self._liveCount)
		if batch <= 0 then
			-- At the concurrency ceiling. Wait for room rather than spawning anyway: the
			-- cap is a performance bound, and blowing it degrades the game for everyone.
			task.wait(0.5)
			continue
		end

		local points = WaveTable.spawnPoints(batch, ArenaConfig.Combat.spawnRadius, 4, rotation)
		for _, point in points do
			self:_spawnOne(template, composition, Vector3.new(point.X, point.Y, point.Z))
		end
		remaining -= batch
	end
end

function WaveService:_spawnOne(template: Model, composition, position: Vector3)
	self._nextEntityId += 1
	local id = `enemy-{self._nextEntityId}`

	local enemy = template:Clone()
	enemy.Name = id
	-- The id the rewind history and the hit resolver both key on. They MUST agree, or
	-- every claimed hit resolves against an entity with no recorded positions.
	enemy:SetAttribute("EntityId", id)
	enemy:SetAttribute("Elite", composition.elite)

	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = composition.health
		humanoid.Health = composition.health
		humanoid.WalkSpeed = composition.speed
		humanoid.Died:Connect(function()
			self:_despawn(id, 3)
		end)
	end

	enemy:PivotTo(CFrame.new(position))
	enemy.Parent = Workspace

	self._live[id] = enemy
	self._liveCount += 1
	self:_replicate()
end

function WaveService:_despawn(id: string, delay: number?)
	local enemy = self._live[id]
	if enemy == nil then
		return
	end
	self._live[id] = nil
	self._liveCount -= 1
	self._combat:ForgetEntity(id)
	self:_replicate()

	if delay and delay > 0 then
		task.delay(delay, function()
			enemy:Destroy()
		end)
	else
		enemy:Destroy()
	end
end

--[[ Called by CombatService when a hit brings an enemy to zero. ]]
function WaveService:OnEnemyKilled(_id: unknown, killer: Player?)
	self._enemiesKilled += 1
	local rewards = self._registry:Find("Rewards")
	if rewards and killer then
		rewards:GrantKill(killer)
	end
end

function WaveService:_endRun(runId: number, reason: string)
	self._runActive = false
	self._round:SetObjectiveMet(false)

	-- Clear the field. A finished run must not leave enemies standing in the results
	-- screen, and every entity has to leave the rewind history with it.
	for id in self._live do
		self:_despawn(id, 0)
	end

	local victory = reason == "objective-met"
	print(
		`[forge] run {runId} ended: {reason} (waves cleared {self._wavesCleared}, kills {self._enemiesKilled})`
	)

	local rewards = self._registry:Find("Rewards")
	if rewards then
		rewards:GrantRun(runId, self._wavesCleared, self._enemiesKilled, victory)
	end

	self._wave = 0
	self:_replicate()
end

--[[
	Publish run state for the HUD. Attributes rather than a remote: this is a handful of
	small scalars that every client wants, Roblox already replicates attributes efficiently,
	and there is nothing secret here -- knowing the wave number does not help an exploiter.
]]
function WaveService:_replicate()
	local state = ReplicatedStorage:FindFirstChild("ArenaState")
	if state == nil then
		state = Instance.new("Configuration")
		state.Name = "ArenaState"
		state.Parent = ReplicatedStorage
	end
	state:SetAttribute("Phase", self._round:Phase())
	state:SetAttribute("Wave", self._wave)
	state:SetAttribute("WaveCount", ArenaConfig.Waves.count)
	state:SetAttribute("EnemiesAlive", self._liveCount)
	state:SetAttribute("WavesCleared", self._wavesCleared)
	state:SetAttribute("Remaining", self._round:Remaining() or 0)
end

return WaveService
