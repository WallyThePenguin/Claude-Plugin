--!strict
-- NativeRig: spawn REAL native R15 rigs from code (no trusted asset). CreateHumanoidModelFromDescription
-- gives a real R15 rig (15 MeshParts + RigAttachment pairs) but ZERO Motor6Ds; we build the 15 joints from
-- the attachment pairs (Humanoid:BuildRigFromAttachments does NOT — verified live), then strip the
-- joint-upgrade AnimationConstraints/BallSocketConstraints (MIXED rigs half-play Motor6D clips —
-- joint_census FAILs them). Then place on the baseplate, anchor the root, and (block only) flat-color each
-- part so poses read clearly in captures. The Async spawns YIELD (web-backed) — call from a tool, not a
-- tight loop. All mechanisms proven via the dev bridge.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local NativeRig = {}

-- {jointName, parentPartName, childPartName} — canonical R15 hierarchy. The RigAttachment on each part is
-- named jointName.."RigAttachment"; the Motor6D goes in Part0 (the parent).
local JOINT_MAP: { { string } } = {
	{ "Root", "HumanoidRootPart", "LowerTorso" },
	{ "Waist", "LowerTorso", "UpperTorso" },
	{ "Neck", "UpperTorso", "Head" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm" },
	{ "RightElbow", "RightUpperArm", "RightLowerArm" },
	{ "RightWrist", "RightLowerArm", "RightHand" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm" },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm" },
	{ "LeftWrist", "LeftLowerArm", "LeftHand" },
	{ "RightHip", "LowerTorso", "RightUpperLeg" },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg" },
	{ "RightAnkle", "RightLowerLeg", "RightFoot" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg" },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot" },
}

local PALETTE: { Color3 } = {
	Color3.fromRGB(230, 25, 75),
	Color3.fromRGB(60, 180, 75),
	Color3.fromRGB(255, 225, 25),
	Color3.fromRGB(0, 130, 200),
	Color3.fromRGB(245, 130, 48),
	Color3.fromRGB(145, 30, 180),
	Color3.fromRGB(70, 240, 240),
	Color3.fromRGB(240, 50, 230),
	Color3.fromRGB(210, 245, 60),
	Color3.fromRGB(250, 190, 212),
	Color3.fromRGB(0, 128, 128),
	Color3.fromRGB(220, 190, 255),
	Color3.fromRGB(170, 110, 40),
	Color3.fromRGB(128, 0, 0),
	Color3.fromRGB(170, 255, 195),
	Color3.fromRGB(255, 255, 255),
}

NativeRig.JOINT_MAP = JOINT_MAP
NativeRig.PALETTE = PALETTE

-- Build the Motor6Ds from the RigAttachment pairs. Skips a joint that already exists (idempotent) or whose
-- parts/attachments are missing. Returns the count built.
function NativeRig.buildJoints(model: Instance): number
	local built = 0
	for _, j in JOINT_MAP do
		local jointName, p0Name, p1Name = j[1], j[2], j[3]
		local p0 = model:FindFirstChild(p0Name)
		local p1 = model:FindFirstChild(p1Name)
		if p0 ~= nil and p1 ~= nil and p0:FindFirstChild(jointName) == nil then
			local a0 = p0:FindFirstChild(jointName .. "RigAttachment")
			local a1 = p1:FindFirstChild(jointName .. "RigAttachment")
			if a0 ~= nil and a1 ~= nil and a0:IsA("Attachment") and a1:IsA("Attachment") then
				local m = Instance.new("Motor6D")
				m.Name = jointName
				m.Part0 = p0 :: BasePart
				m.Part1 = p1 :: BasePart
				m.C0 = a0.CFrame
				m.C1 = a1.CFrame
				m.Parent = p0
				built += 1
			end
		end
	end
	return built
end

-- Lift the model so its lowest extent sits ~0.5 above the baseplate (y=0).
function NativeRig.placeOnBaseplate(model: Model)
	local cf, size = model:GetBoundingBox()
	local bottom = cf.Position.Y - size.Y / 2
	model:PivotTo(model:GetPivot() + Vector3.new(0, 0.5 - bottom, 0))
end

function NativeRig.anchorRoot(model: Instance)
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") then
		hrp.Anchored = true
	end
end

-- Flat distinct color per part + cleared avatar textures, so poses read clearly in captures.
function NativeRig.colorParts(model: Instance)
	local i = 0
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			i += 1
			if d:IsA("MeshPart") then
				d.TextureID = ""
				local sa = d:FindFirstChildOfClass("SurfaceAppearance")
				if sa ~= nil then
					sa:Destroy()
				end
			end
			d.Color = PALETTE[(i - 1) % #PALETTE + 1]
			d.Material = Enum.Material.SmoothPlastic
		end
	end
end

local function finish(model: Model, colored: boolean): Model
	model.Name = "AgentRig"
	model.Parent = Workspace
	NativeRig.buildJoints(model)
	-- Avatar Joint Upgrade rigs ship AnimationConstraints (+BallSocketConstraints) that override /
	-- ignore the Motor6D animation channel — the T-pose trap joint_census caught live (oracle catch
	-- #1). Strip them so spawn_rig yields a uniform CLASSIC Motor6D rig (same conversion PlayBridge
	-- applies to play-mode characters).
	for _, d in model:GetDescendants() do
		if d:IsA("AnimationConstraint") or d:IsA("BallSocketConstraint") then
			d:Destroy()
		end
	end
	NativeRig.placeOnBaseplate(model)
	NativeRig.anchorRoot(model)
	if colored then
		NativeRig.colorParts(model)
	end
	return model
end

-- Spawn the R15 BLOCK rig (default description). YIELDS. Returns (model, nil) or (nil, errString).
function NativeRig.spawnBlock(): (Model?, string?)
	local ok, result = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(
			Instance.new("HumanoidDescription"),
			Enum.HumanoidRigType.R15
		)
	end)
	if not ok or typeof(result) ~= "Instance" then
		return nil, "CreateHumanoidModelFromDescriptionAsync failed: " .. tostring(result)
	end
	return finish(result :: Model, true), nil
end

-- Spawn a real avatar (mesh) from a userId. YIELDS. Returns (model, nil) or (nil, errString).
function NativeRig.spawnAvatar(userId: number): (Model?, string?)
	local ok, result = pcall(function()
		return Players:CreateHumanoidModelFromUserIdAsync(userId)
	end)
	if not ok or typeof(result) ~= "Instance" then
		return nil,
			"CreateHumanoidModelFromUserIdAsync(" .. tostring(userId) .. ") failed: " .. tostring(
				result
			)
	end
	return finish(result :: Model, false), nil
end

return NativeRig
