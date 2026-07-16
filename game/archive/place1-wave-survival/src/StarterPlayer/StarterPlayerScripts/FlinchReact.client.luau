-- FlinchReact: directional-agnostic hit reaction for the LOCAL player. When health drops, plays
-- the shared upper-body Flinch clip at Action3 priority — one tier BELOW the weapons' Action4
-- attack tracks, so taking a hit visibly staggers the torso WITHOUT canceling your own swing
-- (explicit animation-priority layering). Dev-loop playback uses RegisterKeyframeSequence.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local player = Players.LocalPlayer

local function hook(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end
	local animsFolder = ReplicatedStorage:WaitForChild("GameAnims", 10)
	local flinchSeq = animsFolder and animsFolder:WaitForChild("Flinch", 5)
	if not flinchSeq then
		return
	end
	local ok, id = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(flinchSeq)
	end)
	if not ok or type(id) ~= "string" then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action3
	track.Looped = false

	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(health)
		if health < lastHealth and health > 0 then
			track:Play(0.05)
		end
		lastHealth = health
	end)
end

if player.Character then
	task.spawn(hook, player.Character)
end
player.CharacterAdded:Connect(hook)
