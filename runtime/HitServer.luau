-- StudioAgentRuntime.HitServer -- SERVER half of hit detection (roadmap #4; the netcode foundation).
-- Extracted verbatim from bind_hitbox's stamped ItemHitServer template: authoritative hitbox + damage
-- on a hit request, gated by a SERVER-AUTHORITATIVE per-player COOLDOWN (rejects FireServer spam; the
-- algorithm mirrors HitValidator.check, unit-tested in HitValidatorSpec). Finds the CLOSEST struck
-- part per victim Humanoid (R15 limbs are separate parts, so its name is the struck LIMB) and fires
-- the Tool's Hit BindableEvent (model, damage, limb). Heavier netcode (lag-comp rewind, per-limb
-- damage, reconciliation) layers on this seam later.
-- Part of the git-versioned runtime library (runtime/ in the repo; bump runtime/VERSION on change).

local HitServer = {}

-- Wire the authoritative hit handler for `Tool`. The RemoteEvent wait runs spawned so attach never
-- blocks; per-tool cooldown state lives in this closure.
function HitServer.attach(Tool)
	task.spawn(function()
		local rs = game:GetService("ReplicatedStorage")
		local Players = game:GetService("Players")
		local remote = rs:WaitForChild("StudioAgentItemHit", 10)
		if not remote then
			return
		end
		local lastHit = {} -- [player] = os.clock() of last ACCEPTED hit (per-player cooldown state)
		Players.PlayerRemoving:Connect(function(p)
			lastHit[p] = nil
		end)
		remote.OnServerEvent:Connect(function(player, tool)
			if tool ~= Tool then
				return
			end
			local char = player.Character
			local handle = Tool:FindFirstChild("Handle")
			if not (char and handle and Tool.Parent == char) then
				return
			end
			-- AUTHORITATIVE VALIDATION: reject a request faster than the swing cooldown. A rejected
			-- (spam) request does NOT advance the window, so a legitimate swing is never starved.
			local cooldown = tonumber(Tool:GetAttribute("HitCooldown")) or 0.4
			if cooldown < 0 then
				cooldown = 0
			end
			local now = os.clock()
			local prev = lastHit[player]
			if prev ~= nil and (now - prev) < cooldown then
				return -- rejected: on cooldown (anti-spam)
			end
			lastHit[player] = now
			local damage = tonumber(Tool:GetAttribute("HitDamage")) or 25
			local reach = tonumber(Tool:GetAttribute("HitReach")) or 6
			local hitEvent = Tool:FindFirstChild("Hit")
			local struck = {}
			for _, p in workspace:GetPartBoundsInRadius(handle.Position, reach) do
				local model = p:FindFirstAncestorOfClass("Model")
				local hum = model and model:FindFirstChildOfClass("Humanoid")
				if hum and model ~= char then
					local d = (p.Position - handle.Position).Magnitude
					local cur = struck[hum]
					if cur == nil or d < cur.dist then
						struck[hum] = { model = model, part = p, dist = d }
					end
				end
			end
			for hum, info in struck do
				hum:TakeDamage(damage)
				if hitEvent then
					pcall(function()
						hitEvent:Fire(info.model, damage, info.part.Name)
					end)
				end
			end
		end)
	end)
end

return HitServer
