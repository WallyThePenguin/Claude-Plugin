--!strict
-- RigWorkbench: the rig-editor foundation. Read a rig's Motor6D skeleton, visualize it (Neon gizmo
-- markers + bones, like the camera rig's proven parts), and POSE it by setting Motor6D.Transform (the
-- animation channel — applies live in edit). Also spawns a blocky humanoid placeholder (RigTemplates);
-- read/visualize/pose are rig-agnostic (any Motor6D rig, incl. real R6/R15). STATELESS module: operates
-- on rigs in the DataModel; gizmos live under a tagged Workspace folder (found by name, not held).

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local InsertService = game:GetService("InsertService")

local RigTemplates = require(script.Parent.RigTemplates)

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
	finishRecording(rid, true)
	redrawIfShown(rig)
	return string.format("reset %d joints on %s", #joints, rig.Name), true
end

-- ---- spawn ----

-- Load a rig from a TRUSTED asset id via InsertService. NOTE: LoadAsset is gated by Roblox's
-- asset-trust rule — it only works for assets OWNED by this place's creator (or whitelisted); the
-- official Roblox rig ids fail with "Asset is not trusted for this place" (verified live), and there is
-- no RigBuilderService API, so we can't auto-load the native rig. This is for when the user passes
-- their OWN published rig's id. LoadAsset YIELDS + hits the network, so it runs OUTSIDE any
-- ChangeHistory recording. Returns (rig, nil) or (nil, errorString).
local function loadNativeRig(assetId: number, templateName: string): (Instance?, string?)
	local ok, wrapper = pcall(function()
		return InsertService:LoadAsset(assetId)
	end)
	if not ok or typeof(wrapper) ~= "Instance" then
		return nil, tostring(wrapper)
	end
	local rig = wrapper:FindFirstChildWhichIsA("Model")
	if rig == nil then
		wrapper:Destroy()
		return nil, "loaded asset had no rig Model inside"
	end
	local rid = beginRecording("Spawn native rig")
	rig.Name = "AgentRig_" .. string.upper(templateName)
	rig.Parent = Workspace
	pcall(function()
		rig:MakeJoints() -- glue Motor6Ds if the asset relies on legacy joint connectors
	end)
	pcall(function()
		(rig :: Model):MoveTo(Vector3.new(0, 0, 0)) -- stand it on the baseplate
	end)
	finishRecording(rid, true)
	wrapper:Destroy()
	return rig, nil
end

-- Programmatic blocky placeholder (correct-by-construction joints) — the fallback when no native asset
-- exists for the type (e.g. r6) or LoadAsset fails.
local function buildPlaceholder(templateName: string): (Instance?, string)
	local template = RigTemplates.get(templateName)
	if template == nil then
		return nil, "unknown rig type '" .. templateName .. "' (try 'r6' or 'r15')"
	end
	local rid = beginRecording("Spawn rig")
	local model = Instance.new("Model")
	model.Name = "AgentRig_" .. string.upper(templateName)
	local parts: { [string]: BasePart } = {}
	for _, pt in template.parts do
		local p = Instance.new("Part")
		p.Name = pt.name
		p.Size = pt.size
		p.CFrame = CFrame.new(pt.pos)
		p.Anchored = pt.name == "HumanoidRootPart"
		p.Color = if pt.name == "Head"
			then Color3.fromRGB(255, 200, 120)
			else Color3.fromRGB(160, 160, 170)
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		parts[pt.name] = p
	end
	for _, j in template.joints do
		local p0, p1, host = parts[j.part0], parts[j.part1], parts[j.host]
		if p0 ~= nil and p1 ~= nil and host ~= nil then
			local pivot = CFrame.new(j.pivot)
			local motor = Instance.new("Motor6D")
			motor.Name = j.name
			motor.Part0 = p0
			motor.Part1 = p1
			motor.C0 = p0.CFrame:Inverse() * pivot
			motor.C1 = p1.CFrame:Inverse() * pivot
			motor.Parent = host
		end
	end
	local hum = Instance.new("Humanoid")
	if string.lower(templateName) == "r15" then
		hum.RigType = Enum.HumanoidRigType.R15
	end
	hum.Parent = model
	model.PrimaryPart = parts["HumanoidRootPart"]
	model.Parent = Workspace
	finishRecording(rid, true)
	return model, "spawned " .. model.Name .. " (programmatic placeholder)"
end

-- Spawn a rig. With a TRUSTED assetId (a rig you own), load it via InsertService. Otherwise (or if the
-- load fails) build the programmatic rig. Auto-loading the official Roblox rig is impossible (LoadAsset
-- trust gate + no RigBuilderService) — for the native art, generate a rig via Studio's Avatar > Character
-- (Rig Builder) and operate on it with get_rig/pose_joint (they work on any Motor6D rig).
function RigWorkbench.spawn(templateName: string, assetId: number?): (Instance?, string)
	if assetId ~= nil then
		local native, err = loadNativeRig(assetId, templateName)
		if native ~= nil then
			return native, "spawned native rig (asset " .. tostring(assetId) .. ") " .. native.Name
		end
		local model, note = buildPlaceholder(templateName)
		if model ~= nil then
			return model,
				note .. " — native asset " .. tostring(assetId) .. " did not load (" .. tostring(
					err
				) .. ")"
		end
		return nil, note
	end
	return buildPlaceholder(templateName)
end

return RigWorkbench
