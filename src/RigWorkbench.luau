--!strict
-- RigWorkbench: the rig-editor foundation. Read a rig's Motor6D skeleton, visualize it (Neon gizmo
-- markers + bones, like the camera rig's proven parts), and POSE it by setting Motor6D.Transform then
-- applyPose() (Animator:StepAnimations, which makes the pose VISIBLE in edit — moving joints relative to
-- the body; Transform alone doesn't move parts in static edit — verified live). Spawns a real native R15
-- rig via NativeRig (block or avatar). read/visualize/pose are rig-agnostic (any Motor6D rig). STATELESS
-- module: operates on rigs in the DataModel; gizmos live under a tagged Workspace folder (found by name).

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local NativeRig = require(script.Parent.NativeRig)

local RigWorkbench = {}

local SKELETON_FOLDER = "__StudioAgentRigSkeleton"
local SKELETON_TAG = "StudioAgentRigSkeleton"

-- ---- pure helpers (no DataModel — unit-testable) ----

-- Degrees (x,y,z) -> a rotation CFrame.
function RigWorkbench.rotationCFrame(rx: number, ry: number, rz: number): CFrame
	return CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
end

-- Compose a pose: relative multiplies onto the current Transform; absolute replaces it.
function RigWorkbench.applyRotation(current: CFrame, rot: CFrame, relative: boolean): CFrame
	if relative then
		return current * rot
	end
	return rot
end

-- ---- rig reading ----

function RigWorkbench.jointsOf(rig: Instance): { Motor6D }
	local out: { Motor6D } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			table.insert(out, d)
		end
	end
	return out
end

-- Find a joint by exact Name, else case-insensitive. nil if absent.
function RigWorkbench.findJoint(rig: Instance, name: string): Motor6D?
	local lower = string.lower(name)
	local fallback: Motor6D? = nil
	for _, m in RigWorkbench.jointsOf(rig) do
		if m.Name == name then
			return m
		end
		if string.lower(m.Name) == lower then
			fallback = m
		end
	end
	return fallback
end

-- Readable joint list + a name list (for errors). (text, names).
function RigWorkbench.readSkeleton(rig: Instance): (string, { string })
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return "no Motor6D joints found under " .. rig.Name .. " (is this a rig?)", {}
	end
	local lines: { string } = { string.format("%s — %d joints:", rig.Name, #joints) }
	local names: { string } = {}
	for _, m in joints do
		table.insert(names, m.Name)
		local p0 = if m.Part0 ~= nil then m.Part0.Name else "?"
		local p1 = if m.Part1 ~= nil then m.Part1.Name else "?"
		local posed = if m.Transform ~= CFrame.identity then " [posed]" else ""
		table.insert(lines, string.format("- %s: %s -> %s%s", m.Name, p0, p1, posed))
	end
	return table.concat(lines, "\n"), names
end

-- ---- skeleton visualization (Neon gizmo parts; proven to render, like the camera rig) ----

local function clearFolder()
	local f = Workspace:FindFirstChild(SKELETON_FOLDER)
	if f ~= nil then
		f:Destroy()
	end
end

function RigWorkbench.clearSkeleton()
	clearFolder()
end

local function marker(folder: Instance, color: Color3, size: Vector3, cf: CFrame, name: string)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Locked = true
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = folder
end

-- A ball at each joint's world pivot + a bone from the pivot to Part1's center.
function RigWorkbench.drawSkeleton(rig: Instance)
	clearFolder()
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = SKELETON_FOLDER
	CollectionService:AddTag(folder, SKELETON_TAG)
	for _, m in joints do
		local p0, p1 = m.Part0, m.Part1
		if p0 ~= nil and p1 ~= nil then
			local jointPos = (p0.CFrame * m.C0).Position
			marker(
				folder,
				Color3.fromRGB(0, 255, 120),
				Vector3.new(0.5, 0.5, 0.5),
				CFrame.new(jointPos),
				m.Name .. "_joint"
			)
			local target = p1.Position
			local dist = (target - jointPos).Magnitude
			if dist > 0.05 then
				marker(
					folder,
					Color3.fromRGB(80, 160, 255),
					Vector3.new(0.12, 0.12, dist),
					CFrame.lookAt((jointPos + target) / 2, target),
					m.Name .. "_bone"
				)
			end
		end
	end
	folder.Parent = Workspace
end

-- ---- posing (ChangeHistory like create_instance) ----

local function beginRecording(name: string): string?
	if RunService:IsEdit() then
		return ChangeHistoryService:TryBeginRecording(name)
	end
	return nil
end

local function finishRecording(rid: string?, commit: boolean)
	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if commit
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end
end

local function redrawIfShown(rig: Instance)
	if Workspace:FindFirstChild(SKELETON_FOLDER) ~= nil then
		RigWorkbench.drawSkeleton(rig)
	end
end

-- Make Motor6D.Transform poses VISIBLE in edit. Writing Transform alone does NOT move parts in static edit
-- (verified live); the animation system applies it. Get-or-create the rig's Animator and StepAnimations(0),
-- which re-solves the rig from its Transforms — moving joints RELATIVE to the body (root + unposed limbs
-- stay; children follow their parent). NEVER set part CFrames directly (that rigidly drags the whole
-- assembly). No-op (Transform still set) if the rig has no Humanoid/AnimationController.
function RigWorkbench.applyPose(rig: Instance)
	local controller = rig:FindFirstChildOfClass("Humanoid")
		or rig:FindFirstChildOfClass("AnimationController")
	if controller == nil then
		return
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	pcall(function()
		(animator :: Animator):StepAnimations(0)
	end)
end

-- Pose one joint by Name (degrees x/y/z). relative accumulates onto the current Transform. (note, ok).
function RigWorkbench.poseJoint(
	rig: Instance,
	jointName: string,
	rx: number,
	ry: number,
	rz: number,
	relative: boolean
): (string, boolean)
	local m = RigWorkbench.findJoint(rig, jointName)
	if m == nil then
		local _, names = RigWorkbench.readSkeleton(rig)
		return "no joint named '" .. jointName .. "'. Joints: " .. table.concat(names, ", "), false
	end
	local rot = RigWorkbench.rotationCFrame(rx, ry, rz)
	local rid = beginRecording("Pose " .. m.Name)
	m.Transform = RigWorkbench.applyRotation(m.Transform, rot, relative)
	RigWorkbench.applyPose(rig)
	finishRecording(rid, true)
	redrawIfShown(rig)
	return string.format(
		"posed %s by (%g, %g, %g)%s",
		m.Name,
		rx,
		ry,
		rz,
		if relative then " [relative]" else " [absolute]"
	),
		true
end

-- Reset every joint's Transform to identity. (note, ok).
function RigWorkbench.resetPose(rig: Instance): (string, boolean)
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return "no joints to reset under " .. rig.Name, false
	end
	local rid = beginRecording("Reset pose")
	for _, m in joints do
		m.Transform = CFrame.identity
	end
	RigWorkbench.applyPose(rig)
	finishRecording(rid, true)
	redrawIfShown(rig)
	return string.format("reset %d joints on %s", #joints, rig.Name), true
end

-- ---- spawn (delegates to NativeRig) ----

-- Spawn a native R15 rig. type "block" (default) = CreateHumanoidModelFromDescription; "avatar" = a mesh
-- character from a userId (default 1). Both build the Motor6Ds, sit on the baseplate, and anchor the root;
-- block also flat-colors each part. DEDUP (live bug 2026-07-10: every call stacked another "AgentRig"):
-- an existing workspace.AgentRig is REUSED by default (healed: attribute re-stamped, black
-- BodyColors/HumanoidDescription stripped on the block path); fresh=true destroys it and builds new;
-- duplicates beyond the first are destroyed either way. (Async/web — YIELDS.) Returns (model, note) or
-- (nil, errorNote).
function RigWorkbench.spawn(rigType: string, userId: number?, fresh: boolean?): (Instance?, string)
	local isAvatar = string.lower(rigType) == "avatar"
	local existing = NativeRig.findExisting()
	local destroyed = 0
	for i = 2, #existing do
		existing[i]:Destroy()
		destroyed += 1
	end
	local kept: Model? = existing[1]
	if kept ~= nil and fresh ~= true then
		NativeRig.heal(kept, not isAvatar)
		local note = "reused existing rig at "
			.. kept:GetFullName()
			.. " (healed; pass fresh=true to rebuild)"
		if destroyed > 0 then
			note ..= string.format(" — destroyed %d duplicate AgentRig(s)", destroyed)
		end
		return kept, note
	end
	if kept ~= nil then
		kept:Destroy()
		destroyed += 1
	end
	local suffix = if destroyed > 0
		then string.format(" — destroyed %d pre-existing AgentRig(s)", destroyed)
		else ""
	if isAvatar then
		local model, err = NativeRig.spawnAvatar(userId or 1)
		if model == nil then
			return nil, "spawn_rig avatar: " .. tostring(err)
		end
		return model, "spawned avatar rig at " .. model:GetFullName() .. suffix
	end
	local model, err = NativeRig.spawnBlock()
	if model == nil then
		return nil, "spawn_rig block: " .. tostring(err)
	end
	return model, "spawned native R15 block rig at " .. model:GetFullName() .. suffix
end

return RigWorkbench
