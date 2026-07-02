-- StudioAgentRuntime.NpcAI -- SERVER-side enemy AI state machine (roadmap #5), ANIMATED (v4).
-- Perception-driven idle -> chase -> attack (config from the model's Npc* attributes; decide
-- mirrors the spec-tested NpcBrain.decideState), server-authoritative, NpcState attribute tracks
-- the state. v4: the brain PLAYS ITS BODY — clips from the model's AnimSaves (huskIdle loop,
-- huskChase loop, huskAttack one-shot whose HitFrame marker times the damage, huskDeath collapse
-- + fade on Died). Dev-loop playback uses RegisterKeyframeSequence (Studio sessions).
-- Part of the git-versioned runtime library (runtime/ in the repo; bump runtime/VERSION on change).

local NpcAI = {}

-- Run the AI loop for `NPC` (a Model with Humanoid + HumanoidRootPart). The loop runs spawned so
-- attach never blocks the launcher's require.
function NpcAI.attach(NPC)
	task.spawn(function()
		local Players = game:GetService("Players")
		local KSP = game:GetService("KeyframeSequenceProvider")
		local TweenService = game:GetService("TweenService")
		local hum = NPC:FindFirstChildOfClass("Humanoid")
		local hrp = NPC:FindFirstChild("HumanoidRootPart")
		if not (hum and hrp) then
			return
		end

		-- ---- animation: register AnimSaves clips onto a server-side Animator ----
		local animator = hum:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = hum
		end
		local tracks = {}
		local saves = NPC:FindFirstChild("AnimSaves")
		if saves then
			local spec = {
				idle = { clip = "huskIdle", looped = true, priority = Enum.AnimationPriority.Idle },
				chase = { clip = "huskChase", looped = true, priority = Enum.AnimationPriority.Movement },
				attack = { clip = "huskAttack", looped = false, priority = Enum.AnimationPriority.Action },
				death = { clip = "huskDeath", looped = false, priority = Enum.AnimationPriority.Action4 },
			}
			for key, s in spec do
				local ks = saves:FindFirstChild(s.clip)
				if ks and ks:IsA("KeyframeSequence") then
					local ok, id = pcall(function()
						return KSP:RegisterKeyframeSequence(ks)
					end)
					if ok and type(id) == "string" then
						local anim = Instance.new("Animation")
						anim.AnimationId = id
						local track = animator:LoadAnimation(anim)
						track.Looped = s.looped
						track.Priority = s.priority
						tracks[key] = track
					end
				end
			end
		end
		local currentLoop = nil
		local function playLoop(key)
			if currentLoop == key then
				return
			end
			if currentLoop and tracks[currentLoop] then
				pcall(function()
					tracks[currentLoop]:Stop(0.2)
				end)
			end
			currentLoop = key
			if key and tracks[key] then
				pcall(function()
					tracks[key]:Play(0.2)
				end)
			end
		end

		-- ---- death: collapse, fade, remove (RoundLoop counts Died before any of this) ----
		local dead = false
		hum.Died:Connect(function()
			if dead then
				return
			end
			dead = true
			NPC:SetAttribute("NpcState", "dead")
			playLoop(nil)
			pcall(function()
				hrp.Anchored = true
			end)
			if tracks.death then
				pcall(function()
					tracks.death:Play(0.05)
				end)
			end
			task.wait(0.7)
			for _, d in NPC:GetDescendants() do
				if d:IsA("BasePart") then
					TweenService:Create(d, TweenInfo.new(0.6), { Transparency = 1 }):Play()
				end
			end
			task.wait(0.9)
			NPC:Destroy()
		end)

		local function nearest()
			local best, bestDist = nil, nil
			for _, plr in Players:GetPlayers() do
				local c = plr.Character
				local thum = c and c:FindFirstChildOfClass("Humanoid")
				local thrp = c and c:FindFirstChild("HumanoidRootPart")
				if thum and thrp and thum.Health > 0 then
					local d = (thrp.Position - hrp.Position).Magnitude
					if bestDist == nil or d < bestDist then
						best, bestDist = c, d
					end
				end
			end
			return best, bestDist
		end

		local function decide(dist, detect, attack)
			if dist == nil then
				return "idle"
			end
			if dist <= attack then
				return "attack"
			end
			if dist <= detect then
				return "chase"
			end
			return "idle"
		end

		-- Attack strike: play the lunge; damage lands at the clip's HitFrame marker (the
		-- telegraph window is the coil before it) — falls back to a fixed delay markerless.
		local striking = false
		local function strike(target)
			if striking then
				return
			end
			striking = true
			local function damage()
				local c = target
				local thum = c and c:FindFirstChildOfClass("Humanoid")
				local thrp = c and c:FindFirstChild("HumanoidRootPart")
				-- Re-check range at CONTACT (the telegraph is dodgeable).
				local reach = (tonumber(NPC:GetAttribute("NpcAttackRange")) or 6) + 1.5
				if thum and thrp and (thrp.Position - hrp.Position).Magnitude <= reach then
					thum:TakeDamage(tonumber(NPC:GetAttribute("NpcDamage")) or 15)
				end
			end
			if tracks.attack then
				local fired = false
				pcall(function()
					tracks.attack:GetMarkerReachedSignal("HitFrame"):Once(function()
						fired = true
						damage()
					end)
					tracks.attack:Play(0.05)
				end)
				task.delay(0.6, function()
					if not fired then
						damage() -- markerless fallback
					end
					striking = false
				end)
			else
				damage()
				striking = false
			end
		end

		local lastAttack = 0
		while hum.Health > 0 do
			local detect = tonumber(NPC:GetAttribute("NpcDetectRange")) or 40
			local attack = tonumber(NPC:GetAttribute("NpcAttackRange")) or 6
			local cd = tonumber(NPC:GetAttribute("NpcAttackCooldown")) or 1.5
			local target, dist = nearest()
			local state = decide(dist, detect, attack)
			NPC:SetAttribute("NpcState", state)
			if state == "chase" and target then
				playLoop("chase")
				local thrp = target:FindFirstChild("HumanoidRootPart")
				if thrp then
					hum:MoveTo(thrp.Position)
				end
			elseif state == "attack" and target then
				playLoop("idle")
				hum:Move(Vector3.zero)
				if os.clock() - lastAttack >= cd then
					lastAttack = os.clock()
					strike(target)
				end
			else
				playLoop("idle")
				hum:Move(Vector3.zero)
			end
			task.wait(0.2)
		end
	end)
end

return NpcAI
