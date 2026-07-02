-- StudioAgentRuntime.NpcAI -- SERVER-side enemy AI state machine (roadmap #5).
-- Extracted verbatim from make_npc's stamped NpcAI template: perception-driven idle -> chase ->
-- attack (config from the model's Npc* attributes; decide mirrors the spec-tested NpcBrain.decideState),
-- server-authoritative, NpcState attribute tracks the state; dies when the Humanoid's Health hits 0.
-- Part of the git-versioned runtime library (runtime/ in the repo; bump runtime/VERSION on change).

local NpcAI = {}

-- Run the AI loop for `NPC` (a Model with Humanoid + HumanoidRootPart). The loop runs spawned so
-- attach never blocks the launcher's require.
function NpcAI.attach(NPC)
	task.spawn(function()
		local Players = game:GetService("Players")
		local hum = NPC:FindFirstChildOfClass("Humanoid")
		local hrp = NPC:FindFirstChild("HumanoidRootPart")
		if not (hum and hrp) then
			return
		end

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

		local lastAttack = 0
		while hum.Health > 0 do
			local damage = tonumber(NPC:GetAttribute("NpcDamage")) or 15
			local detect = tonumber(NPC:GetAttribute("NpcDetectRange")) or 40
			local attack = tonumber(NPC:GetAttribute("NpcAttackRange")) or 6
			local cd = tonumber(NPC:GetAttribute("NpcAttackCooldown")) or 1.5
			local target, dist = nearest()
			local state = decide(dist, detect, attack)
			NPC:SetAttribute("NpcState", state)
			if state == "chase" and target then
				local thrp = target:FindFirstChild("HumanoidRootPart")
				if thrp then
					hum:MoveTo(thrp.Position)
				end
			elseif state == "attack" and target then
				hum:Move(Vector3.zero)
				if os.clock() - lastAttack >= cd then
					lastAttack = os.clock()
					local thum = target:FindFirstChildOfClass("Humanoid")
					if thum then
						thum:TakeDamage(damage)
					end
				end
			else
				hum:Move(Vector3.zero)
			end
			task.wait(0.2)
		end
		NPC:SetAttribute("NpcState", "dead")
	end)
end

return NpcAI
