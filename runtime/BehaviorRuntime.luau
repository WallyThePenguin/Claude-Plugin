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
		task.wait(active)
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
