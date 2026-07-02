-- StudioAgentRuntime.HitClient -- CLIENT half of hit detection (roadmap #4).
-- Extracted verbatim from bind_hitbox's stamped ItemHitClient template: when the behavior machine's
-- StateChanged hits 'active', request a server-authoritative hit over the shared RemoteEvent. The
-- server does the actual sweep + damage; this only signals the swing moment.
-- Part of the git-versioned runtime library (runtime/ in the repo; bump runtime/VERSION on change).

local HitClient = {}

-- Wire the hit request onto `Tool`. The RemoteEvent wait runs spawned so attach never blocks.
-- MARKER-DRIVEN when the behavior runtime found a HitFrame marker in the use clip
-- (Tool.MarkerDriven): the request fires on the "contact" event (the animation's actual contact
-- frame). Clips without markers fall back to the timer-gated "active" window.
function HitClient.attach(Tool)
	task.spawn(function()
		local rs = game:GetService("ReplicatedStorage")
		local remote = rs:WaitForChild("StudioAgentItemHit", 10)
		local sc = Tool:FindFirstChild("StateChanged")
		if sc and remote then
			sc.Event:Connect(function(state)
				local markerDriven = Tool:GetAttribute("MarkerDriven") == true
				if (markerDriven and state == "contact") or (not markerDriven and state == "active") then
					remote:FireServer(Tool)
				end
			end)
		end
	end)
end

return HitClient
