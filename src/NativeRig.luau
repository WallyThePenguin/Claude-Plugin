--!strict
-- NativeRig: spawn REAL native R15 rigs from code (no trusted asset). CreateHumanoidModelFromDescription
-- gives a real R15 rig (15 MeshParts + RigAttachment pairs) jointed with AnimationConstraints, NOT
-- Motor6Ds — that is the documented Avatar Joint Upgrade default, not an engine quirk
-- (create.roblox.com/docs/reference/engine/classes/AnimationConstraint: "Replaces Motor6D for Avatar
-- rigs"). Our whole authoring stack (pose_joint/AnimationClip/scrubClip/joint_census) is Motor6D-typed
-- (constraints fail IsA("Motor6D") and their C0/C1 are read-only aliases), so we CONVERT: build the 15
-- Motor6Ds from the attachment pairs (Humanoid:BuildRigFromAttachments does NOT — verified live), then
-- strip the AnimationConstraints/BallSocketConstraints (MIXED rigs half-play Motor6D clips —
-- joint_census FAILs them). A constraints-NATIVE migration (docs' Phase 2; IsKinematic=false unlocks
-- ragdoll/physical simulation) is a deliberate future project, not this module's job. Then place on the
-- baseplate, anchor the root, and (block only) flat-color each part so poses read clearly in captures.
-- The Async spawns YIELD (web-backed) — call from a tool, not a tight loop.

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

-- Where the rig stands on the baseplate. NOT the origin: the play-mode player spawns at the
-- origin SpawnLocation, and a rig left there has the player materialize INSIDE it (live capture
-- 2026-07-10). X=6 keeps both in one camera frame without overlap.
local RIG_X = 6
local RIG_Z = 0

-- Place the model at (RIG_X, RIG_Z) with its lowest extent ~0.5 above the baseplate (y=0).
function NativeRig.placeOnBaseplate(model: Model)
	local cf, size = model:GetBoundingBox()
	local bottom = cf.Position.Y - size.Y / 2
	local pivot = model:GetPivot()
	model:PivotTo(CFrame.new(RIG_X, pivot.Position.Y + (0.5 - bottom), RIG_Z) * pivot.Rotation)
end

-- Strip the engine's play-boot repaint channel from a BLOCK rig. The spawned model ships a
-- "Body Colors" BodyColors instance + a HumanoidDescription child under the Humanoid whose colors
-- are ALL (0,0,0) — in edit the palette part colors mask them, but at PLAY boot the engine
-- re-applies BodyColors over part colors and the whole rig renders solid black (live capture
-- 2026-07-10). Destroying both (vs repainting) is the minimal fix: the palette lives on the part
-- colors. NEVER call this on an avatar rig — a real avatar needs its description.
function NativeRig.stripBodyColors(model: Instance)
	local bc = model:FindFirstChildOfClass("BodyColors")
	if bc ~= nil then
		bc:Destroy()
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		local desc = humanoid:FindFirstChildOfClass("HumanoidDescription")
		if desc ~= nil then
			desc:Destroy()
		end
	end
end

-- Every existing Workspace child Model named "AgentRig" with a Humanoid, in child order. Dedup
-- input: spawn reuses the first and destroys the rest (pre-fix, every spawn_rig stacked another).
function NativeRig.findExisting(): { Model }
	local out: { Model } = {}
	for _, d in Workspace:GetChildren() do
		if d:IsA("Model") and d.Name == "AgentRig" and d:FindFirstChildOfClass("Humanoid") ~= nil then
			table.insert(out, d :: Model)
		end
	end
	return out
end

-- Heal a pre-existing rig so reuse is safe: re-stamp the identity attribute, re-place it at the
-- standard off-origin spot (a pre-fix rig sits ON the player spawn; the model pivot move preserves
-- Motor6D poses), and (block rigs only) strip the black BodyColors/HumanoidDescription repaint
-- channel.
function NativeRig.heal(model: Model, colored: boolean)
	model:SetAttribute("StudioAgentGenerated", true)
	NativeRig.placeOnBaseplate(model)
	if colored then
		NativeRig.stripBodyColors(model)
	end
end

function NativeRig.anchorRoot(model: Instance)
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") then
		hrp.Anchored = true
	end
end

-- UV ORIENTATION REFERENCE textures (user-taught 2026-07-11): the blocky rig is front/back
-- symmetric, so swing/pose direction is unreadable in captures without them. These are durable
-- moderation-approved Image assets minted from the R15 UV template pack (FRONT/BACK/L/R/UP/DOWN
-- labels per face). Applied as the DEFAULT block-rig look so no fresh/heal/rebuild can lose the
-- labels (live-caught: a fresh:true respawn silently shed manually-applied textures).
local UV_REF_TORSO = "rbxassetid://98589653316755"
local UV_REF_FACE = "rbxassetid://140582367643150"
local UV_REF_LIMB = "rbxassetid://93485308521965"
local UV_REF_BY_PART: { [string]: string } = {
	UpperTorso = UV_REF_TORSO,
	LowerTorso = UV_REF_TORSO,
	Head = UV_REF_FACE,
}

-- UV-labeled orientation look on every body MeshPart (white base so the labels read crisply);
-- avatar junk (SurfaceAppearance / old TextureID) is stripped first. Non-mesh parts (e.g. the
-- invisible HumanoidRootPart) keep a palette color as before.
function NativeRig.colorParts(model: Instance)
	local i = 0
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			i += 1
			if d:IsA("MeshPart") then
				local sa = d:FindFirstChildOfClass("SurfaceAppearance")
				if sa ~= nil then
					sa:Destroy()
				end
				d.TextureID = UV_REF_BY_PART[d.Name] or UV_REF_LIMB
				d.Color = Color3.new(1, 1, 1)
			else
				d.Color = PALETTE[(i - 1) % #PALETTE + 1]
			end
			d.Material = Enum.Material.SmoothPlastic
		end
	end
end

local function finish(model: Model, colored: boolean): Model
	model.Name = "AgentRig"
	model:SetAttribute("StudioAgentGenerated", true) -- identity marker: game_pull excludes on this
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
		-- Block rig: kill the play-boot black repaint (see stripBodyColors) BEFORE painting the
		-- palette, so the part colors are the only color channel left.
		NativeRig.stripBodyColors(model)
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
