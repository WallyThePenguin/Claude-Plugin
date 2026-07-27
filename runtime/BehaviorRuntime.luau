-- StudioAgentRuntime.BehaviorRuntime -- CLIENT-side Tool state machine + animation (roadmap #3).
-- Extracted verbatim from bind_behavior's stamped ItemBehaviorRuntime template: on equip plays the
-- looped idle clip; on activate runs windup -> active -> cooldown -> idle (durations from the Tool's
-- BehaviorWindup/Active/Cooldown attributes), setting the ItemState attribute + firing StateChanged
-- each transition; re-activation while busy is ignored. Supersedes AnimRuntime (does both).
-- Dev-loop playback uses RegisterKeyframeSequence (solo Studio only); a shipped/multiplayer item
-- needs a published AnimationId + server-authoritative validation (later).
-- Part of the git-versioned runtime library (runtime/ in the repo; bump runtime/VERSION on change).

local BehaviorRuntime = {}

-- Wire the machine onto `Tool`. Non-blocking (connections only); per-tool state lives in this closure.
function BehaviorRuntime.attach(Tool)
	local KSP = game:GetService("KeyframeSequenceProvider")
	local RunService = game:GetService("RunService")
	local stateChanged = Tool:FindFirstChild("StateChanged")
	local tracks = {}
	local token = 0

	local function getAnimator()
		local char = Tool.Parent
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return nil
		end
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		return animator
	end

	local function play(clipName, looped, priority)
		local prev = tracks[clipName]
		if prev then
			pcall(function()
				prev:Stop()
			end)
			tracks[clipName] = nil
		end
		local anims = Tool:FindFirstChild("Anims")
		local ks = anims and anims:FindFirstChild(clipName)
		if not ks then
			return
		end
		local animator = getAnimator()
		if not animator then
			return
		end
		local ok, id = pcall(function()
			return KSP:RegisterKeyframeSequence(ks)
		end)
		if not ok or type(id) ~= "string" then
			return
		end
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local track = animator:LoadAnimation(anim)
		track.Looped = looped
		track.Priority = priority
		track:Play()
		tracks[clipName] = track
		return track
	end

	local function setState(s)
		Tool:SetAttribute("ItemState", s)
		if stateChanged then
			pcall(function()
				stateChanged:Fire(s)
			end)
		end
	end

	local function enterIdle()
		setState("idle")
		play("idle", true, Enum.AnimationPriority.Idle)
	end

	-- Swing audio: distinct whoosh at swing start; the CONNECT thud is server-side (HitServer)
	-- so every client hears confirmed contact. Classic rbxasset ids load everywhere.
	local function ensureSound(name: string, id: string, volume: number)
		local h = Tool:FindFirstChild("Handle")
		if h == nil then
			return nil
		end
		local s = h:FindFirstChild(name)
		if s == nil then
			s = Instance.new("Sound")
			s.Name = name
			s.SoundId = id
			s.Volume = volume
			s.Parent = h
		end
		return s
	end

	-- MARKER-DRIVEN event timing: when the use clip carries a "HitFrame" KeyframeMarker, the
	-- contact event fires from GetMarkerReachedSignal (the animation's actual contact frame),
	-- not the numeric window. StateChanged fires "contact" as an EVENT (ItemState machine is
	-- unchanged); HitClient prefers it when Tool:GetAttribute("MarkerDriven") is true. A
	-- "CancelOpen" marker opens an early-cancel window during cooldown (canCancel).
	local function clipHasMarker(clipName: string, markerName: string): boolean
		local anims = Tool:FindFirstChild("Anims")
		local ks = anims and anims:FindFirstChild(clipName)
		if not (ks and ks:IsA("KeyframeSequence")) then
			return false
		end
		for _, kf in ks:GetKeyframes() do
			for _, m in (kf :: Keyframe):GetMarkers() do
				if m.Name == markerName then
					return true
				end
			end
		end
		return false
	end
	local markerDriven = clipHasMarker("use", "HitFrame")
	Tool:SetAttribute("MarkerDriven", markerDriven)
	local canCancel = false

	Tool.Equipped:Connect(function()
		enterIdle()
	end)

	Tool.Activated:Connect(function()
		local state = Tool:GetAttribute("ItemState")
		-- The CancelOpen marker opens an early re-swing window during cooldown.
		if state ~= "idle" and not (state == "cooldown" and canCancel) then
			return
		end
		token += 1
		local my = token
		canCancel = false
		local windup = tonumber(Tool:GetAttribute("BehaviorWindup")) or 0.15
		local active = tonumber(Tool:GetAttribute("BehaviorActive")) or 0.15
		local cooldown = tonumber(Tool:GetAttribute("BehaviorCooldown")) or 0.4
		setState("windup")
		local whoosh = ensureSound("SwingWhoosh", "rbxasset://sounds/swordslash.wav", 0.6)
		if whoosh then
			pcall(function()
				whoosh:Play()
			end)
		end
		-- Explicit priority layering: attack at Action4 so an Action3 hit-react can layer on the
		-- same rig without canceling the swing (idle stays at Idle priority).
		local track = play("use", false, Enum.AnimationPriority.Action4)
		if track ~= nil and markerDriven then
			pcall(function()
				track:GetMarkerReachedSignal("HitFrame"):Connect(function()
					if my == token and stateChanged then
						pcall(function()
							stateChanged:Fire("contact")
						end)
					end
				end)
				track:GetMarkerReachedSignal("CancelOpen"):Connect(function()
					if my == token then
						canCancel = true
					end
				end)
			end)
		end
		task.wait(windup)
		if my ~= token then
			return
		end
		setState("active")
		-- LUNGE STRIDE (BehaviorLungeStuds > 0): a committed attack travels. It has to be driven
		-- HERE and not by the clip -- measured 2026-07-26 that Roblox's Animator applies JOINT
		-- transforms only, so a root-Pose translation is discarded by the engine (positive control:
		-- the same clip's LowerTorso ramped 0->60 deg while rootZ never moved, anchored OR not).
		-- Spread across the active window so it reads as a drive rather than a teleport, and
		-- raycast-gated ahead of the body so a lunge can never push through a wall.
		local lungeStuds = tonumber(Tool:GetAttribute("BehaviorLungeStuds")) or 0
		local root = if Tool.Parent ~= nil
			then Tool.Parent:FindFirstChild("HumanoidRootPart")
			else nil
		if lungeStuds > 0 and active > 0 and root ~= nil then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { Tool.Parent }
			local moved, started = 0, os.clock()
			while moved < lungeStuds do
				local dt = RunService.Heartbeat:Wait()
				if my ~= token then
					return
				end
				local elapsed = os.clock() - started
				if elapsed >= active then
					break
				end
				local step = math.min(lungeStuds * (dt / active), lungeStuds - moved)
				local dir = root.CFrame.LookVector
				-- probe past the step by roughly half a torso so we stop SHORT of geometry
				if workspace:Raycast(root.Position, dir * (step + 1.5), params) ~= nil then
					break
				end
				root.CFrame = root.CFrame + dir * step
				moved += step
			end
			local remaining = active - (os.clock() - started)
			if remaining > 0 then
				task.wait(remaining)
			end
		else
			task.wait(active)
		end
		if my ~= token then
			return
		end
		setState("cooldown")
		task.wait(cooldown)
		if my ~= token then
			return
		end
		enterIdle()
	end)

	Tool.Unequipped:Connect(function()
		token += 1
		for _, t in tracks do
			pcall(function()
				t:Stop()
			end)
		end
		tracks = {}
		Tool:SetAttribute("ItemState", "idle")
	end)

	-- Heal a missed first equip: if the Tool is ALREADY in a character when attach runs (the
	-- launcher's WaitForChild can land after Tool.Equipped fired), enter idle now.
	if Tool.Parent ~= nil and Tool.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
		enterIdle()
	end
end

return BehaviorRuntime
