--!strict
-- CombatService: records position history and resolves every claimed hit.
--
-- This is the security boundary of the whole game. Everything a player can do that removes
-- health passes through here, and nothing the client says is believed:
--
--   forge-net Router    rate -> validate -> handle -> contain
--   forge-guard         argument shapes, abuse scoring
--   forge-combat        rewind to the claimed instant, re-simulate, decide
--
-- The client reports INTENT. The server decides the outcome. A client's local hit effect is
-- cosmetic and may be wrong.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ServerPackages = ServerScriptService:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Router = require(ServerPackages["forge-net"])
local Guard = require(ServerPackages["forge-guard"])
local Combat = require(ServerPackages["forge-combat"])

local ArenaConfig = require(Shared.ArenaConfig)
local CombatPolicy = require(Shared.CombatPolicy)

local Validate = Guard.Validate

local CombatService = {}
CombatService.Name = "Combat"

function CombatService:Init(registry)
	self._registry = registry
	self._clock = os.clock

	self._history = Combat.History.new({
		windowSeconds = CombatPolicy.WindowSeconds,
		sampleRate = CombatPolicy.SampleRate,
	})

	-- One shared abuse score across every surface, so a player probing several at once
	-- accumulates suspicion rather than staying under three separate thresholds.
	self._abuse = Guard.AbuseScore.new({
		threshold = ArenaConfig.Guard.abuseThreshold,
		decayPerSecond = ArenaConfig.Guard.abuseDecayPerSecond,
	}, self._clock)

	-- Server's record of the last ACCEPTED attack per player. This, not the client's
	-- cooldown timer, is what enforces fire rate.
	self._lastAttack = {} :: { [number]: number }
	self._equipped = {} :: { [number]: string }
	self._lastSample = {} :: { [number]: { position: any, at: number } }

	self._router = Router.new({
		onReject = function(player, route, kind, reason)
			if player then
				self._abuse:Report(player.UserId, kind)
				if reason then
					warn(`[combat] {player.Name} rejected on {route}: {reason}`)
				end
			end
		end,
		onError = function(_player, route, err)
			warn(`[combat] {route} threw: {err}`)
		end,
	})

	self._router:Route("Swing", {
		rateLimit = Guard.RateLimit.new(ArenaConfig.Net.swing, self._clock),
		-- Arity included. A client can send zero arguments to this, or thirty.
		validate = Validate.tuple({
			-- The claimed attack time. Bounded hard: forge-combat rejects the future and
			-- anything past the rewind window anyway, but a wild value should never get
			-- that far.
			Validate.number({ min = 0, max = 1e9 }),
			Validate.vector3({ maxMagnitude = 1e4 }),
			Validate.instanceOf("Humanoid"),
		}),
		handler = function(player, at, origin, targetHumanoid)
			self:_resolveSwing(player, at, origin, targetHumanoid)
		end,
	})

	-- An unlimited route should be a visible decision, never an oversight.
	for _, name in self._router:UnlimitedRoutes() do
		warn(`[combat] route {name} has no rate limit`)
	end
end

function CombatService:Start()
	self._swingRemote = self:_ensureRemote("Swing")
	self._swingRemote.OnServerEvent:Connect(function(player, ...)
		self._router:Dispatch("Swing", player, ...)
	end)

	-- Sample every character on a fixed cadence. This IS the rewind buffer; without it
	-- forge-combat has nothing to re-simulate against.
	local accumulator = 0
	local interval = 1 / CombatPolicy.SampleRate
	RunService.Heartbeat:Connect(function(delta)
		accumulator += delta
		if accumulator < interval then
			return
		end
		accumulator = 0
		self:_sample()
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Every per-player table gets cleaned up. One that does not is both a leak and a
		-- denial-of-service surface for an attacker cycling identities.
		self._history:Forget(player.UserId)
		self._abuse:Forget(player.UserId)
		self._router:Forget(player)
		self._lastAttack[player.UserId] = nil
		self._equipped[player.UserId] = nil
		self._lastSample[player.UserId] = nil
	end)

	game:BindToClose(function()
		self._router:Close()
	end)
end

function CombatService:_ensureRemote(name: string): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	local remote = folder:FindFirstChild(name)
	if remote == nil then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	return remote :: RemoteEvent
end

function CombatService:_sample()
	local now = self._clock()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root == nil then
			continue
		end

		local position = (root :: BasePart).Position
		self._history:Record(player.UserId, position, now)

		-- Movement plausibility. Evidence, never a verdict: Roblox replicates character
		-- physics from the client by design, so a single impossible sample is lag.
		local previous = self._lastSample[player.UserId]
		if previous then
			local violations =
				Guard.Movement.check(previous.position, position, now - previous.at, {
					maxSpeed = ArenaConfig.Combat.maxPlayerSpeed,
					maxStep = ArenaConfig.Combat.arenaRadius,
					minY = ArenaConfig.Combat.minY,
					maxY = ArenaConfig.Combat.maxY,
				})
			for _, violation in violations do
				self._abuse:Report(player.UserId, violation.kind, violation.weight)
			end
		end
		self._lastSample[player.UserId] = { position = position, at = now }
	end
end

--[[
	Record an NPC's position so it can be rewound too. Called by the wave service every
	sample tick -- without this, a hit on a moving enemy resolves against nothing.
]]
function CombatService:RecordEntity(id: unknown, position: Vector3)
	self._history:Record(id, position, self._clock())
end

function CombatService:ForgetEntity(id: unknown)
	self._history:Forget(id)
end

function CombatService:SetEquipped(player: Player, weapon: string?)
	self._equipped[player.UserId] = weapon
end

function CombatService:_resolveSwing(
	player: Player,
	at: number,
	origin: Vector3,
	targetHumanoid: Humanoid
)
	local weaponName = self._equipped[player.UserId]
	local weapon = weaponName and ArenaConfig.Weapons[weaponName]
	if weapon == nil then
		self._abuse:Report(player.UserId, "no-weapon")
		return
	end

	local targetModel = targetHumanoid.Parent
	local targetRoot = targetModel and targetModel:FindFirstChild("HumanoidRootPart")
	if targetRoot == nil then
		return
	end

	-- The entity id used for history must match what the wave service records under.
	local targetId = targetModel:GetAttribute("EntityId")
	if targetId == nil then
		return
	end

	local verdict = Combat.Claim.resolve({
		attackerId = player.UserId,
		targetId = targetId,
		at = at,
		origin = origin,
		weapon = { range = weapon.range, cooldown = weapon.cooldown },
	}, {
		now = self._clock(),
		history = self._history,
		lastAcceptedAt = self._lastAttack[player.UserId],
		targetAlive = targetHumanoid.Health > 0,
		weaponEquipped = true,
		sameTeam = false, -- PvE: enemies are never on the player's team.
		lineOfSight = nil,
	}, CombatPolicy.Policy)

	if not verdict.accepted then
		self._abuse:Report(player.UserId, verdict.reason)
		if self._abuse:Exceeded(player.UserId) then
			warn(
				`[combat] {player.Name} over abuse threshold: {game:GetService("HttpService")
					:JSONEncode(self._abuse:Breakdown(player.UserId))}`
			)
		end
		return
	end

	self._lastAttack[player.UserId] = self._clock()

	-- Damage is the SERVER's number, taken from config. The client never supplies it.
	targetHumanoid:TakeDamage(weapon.damage)

	local waves = self._registry:Find("Waves")
	if waves and targetHumanoid.Health <= 0 then
		waves:OnEnemyKilled(targetId, player)
	end
end

function CombatService:AbuseScore(): any
	return self._abuse
end

return CombatService
