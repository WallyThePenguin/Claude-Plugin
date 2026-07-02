-- StudioAgentRuntime.AnimRuntime -- CLIENT-side Tool animation player (roadmap #2).
-- Extracted verbatim from bind_animation's stamped ItemAnimRuntime template: equip plays the looped
-- idle clip, activate plays the one-shot use clip (per-joint Action priority overrides just the arm).
-- Superseded by BehaviorRuntime when bind_behavior runs (it does animation + the state machine).
-- Dev-loop ONLY: RegisterKeyframeSequence playback works in solo Studio, NOT shipped/multiplayer
-- (that needs a published AnimationId).
-- Part of the git-versioned runtime library (runtime/ in the repo; bump runtime/VERSION on change).

local AnimRuntime = {}

-- Wire animation onto `Tool`. Non-blocking; per-tool state lives in this closure.
function AnimRuntime.attach(Tool)
	local KSP = game:GetService("KeyframeSequenceProvider")
	local tracks = {}

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
	end

	Tool.Equipped:Connect(function()
		play("idle", true, Enum.AnimationPriority.Idle)
	end)

	Tool.Activated:Connect(function()
		play("use", false, Enum.AnimationPriority.Action)
	end)

	Tool.Unequipped:Connect(function()
		for _, t in tracks do
			pcall(function()
				t:Stop()
			end)
		end
		tracks = {}
	end)

	-- Heal a missed first equip: if the Tool is ALREADY in a character when attach runs (the
	-- launcher's WaitForChild can land after Tool.Equipped fired), start the idle loop now.
	if Tool.Parent ~= nil and Tool.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
		play("idle", true, Enum.AnimationPriority.Idle)
	end
end

return AnimRuntime
