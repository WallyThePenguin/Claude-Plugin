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

-- Clear by TAG (the folder has parented to Workspace, CoreGui, and now the rig across versions —
-- the tag finds it wherever it lives; also sweeps pre-rewrite Neon-part leftovers).
local function clearFolder()
	for _, inst in CollectionService:GetTagged(SKELETON_TAG) do
		inst:Destroy()
	end
	local f = Workspace:FindFirstChild(SKELETON_FOLDER)
	if f ~= nil then
		f:Destroy()
	end
	local cg = game:GetService("CoreGui"):FindFirstChild(SKELETON_FOLDER)
	if cg ~= nil then
		cg:Destroy()
	end
end

function RigWorkbench.clearSkeleton()
	clearFolder()
end

-- lookAt with a colinear-safe up vector (many joint pivots sit straight along the part's Y).
local function safeLookAt(pos: Vector3, target: Vector3): CFrame
	local dir = (target - pos).Unit
	local up = if math.abs(dir.Y) > 0.9 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(pos, target, up)
end

-- HandleAdornment skeleton (user-validated 2026-07-11): a SphereHandleAdornment at each joint
-- pivot, Adornee = Part1 with CFrame = C1 — the pivot in Part1-LOCAL space, so the gizmo is
-- mathematically welded to the live joint and tracks every pose/animation frame with ZERO
-- redraws (the original static Neon parts froze at draw time and detached the moment the rig
-- moved). Bones run pivot -> part center in the same local space; AlwaysOnTop renders through
-- the model. Weapon joints (AgentEditGrip + any articulated segment chain) get balls
-- automatically — jointsOf enumerates every Motor6D under the rig, tools included.
-- PLATFORM LIMIT (user-confirmed by screenshot vs capture): adornments render in the LIVE
-- viewport but Studio does NOT composite the adornment layer into CaptureScreenshot — this
-- gizmo is a human debugging aid; agent-side verification uses numeric joint probes + the UV
-- orientation textures. (A welded-parts variant was tried and rejected: parts inside the rig
-- pollute the oracle's part/weld censuses.)
function RigWorkbench.drawSkeleton(rig: Instance)
	clearFolder()
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = SKELETON_FOLDER
	CollectionService:AddTag(folder, SKELETON_TAG)
	folder:SetAttribute("StudioAgentGenerated", true)
	for _, m in joints do
		local p0, p1 = m.Part0, m.Part1
		if p0 ~= nil and p1 ~= nil then
			local ball = Instance.new("SphereHandleAdornment")
			ball.Name = m.Name .. "_joint"
			ball.Adornee = p1
			ball.CFrame = m.C1
			ball.Radius = 0.14
			ball.Color3 = Color3.fromRGB(0, 255, 120)
			ball.Transparency = 0.15
			ball.AlwaysOnTop = true
			ball.ZIndex = 2
			ball.Parent = folder
			local pivotLocal = m.C1.Position
			local len = pivotLocal.Magnitude
			if len > 0.05 then
				local bone = Instance.new("CylinderHandleAdornment")
				bone.Name = m.Name .. "_bone"
				bone.Adornee = p1
				bone.CFrame = safeLookAt(pivotLocal / 2, Vector3.zero)
				bone.Height = len
				bone.Radius = 0.045
				bone.Color3 = Color3.fromRGB(80, 160, 255)
				bone.Transparency = 0.25
				bone.AlwaysOnTop = true
				bone.ZIndex = 1
				bone.Parent = folder
			end
		end
	end
	-- Lives inside the rig: dies with it automatically; tagged + generated-stamped for cleanup
	-- sweeps and game_pull exclusion.
	folder.Parent = rig
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

-- Adornment gizmos track adornee parts live, so pose changes need no redraw; this only rebuilds
-- when the JOINT SET may have changed (kept for those callers; the tag finds the folder wherever
-- any version parented it).
local function redrawIfShown(rig: Instance)
	if #CollectionService:GetTagged(SKELETON_TAG) > 0 then
		RigWorkbench.drawSkeleton(rig)
	end
end

-- CHANNEL DOCTRINE (tooling issue #23 add-keyframe-batch-frozen-snapshot, resolved by reading the code):
-- WRITE channel: pose_joint and add_keyframe's poses batch write Motor6D.Transform (NEVER C0), then
-- applyPose -> Animator:StepAnimations(0) renders it. READ channel: the keyframe snapshot
-- (AnimationClip.currentTransforms -> buildPoseTree) reads Motor6D.Transform — the SAME channel; C0 is
-- read by NEITHER side. The frozen-snapshot lie was therefore not a write/read channel split:
-- StepAnimations is not a pure renderer — every AnimationTrack the Animator has loaded (playing OR merely
-- Stop()ed: a track LINGERS in edit and keeps overriding manual poses — live-verified in
-- Tools/Capture.luau's capture_animation restore) RE-STAMPS its sampled pose into Motor6D.Transform on
-- each call, clobbering the authored write between apply and snapshot. grip_tool's arm-hold C0 residue
-- (issue #24) skews only the RENDERED/captured pose; it never enters the stored keyframes. Fixes:
-- purgeTracks() before any pose authoring (below) + Animate's verify-after-apply read-back.

-- Purge the rig's Animator of loaded AnimationTracks before authoring a pose. Stop(0) alone does NOT
-- remove a track in edit — it lingers and re-stamps on every StepAnimations (capture_animation's
-- live-verified finding: only DESTROYING the Animator removes it), so after stopping we destroy the
-- Animator in edit; applyPose get-or-creates a clean one on its next call. In play (a live character)
-- we only Stop(0) — destroying a runtime Animator would break the game's own animate scripts.
-- Returns how many PLAYING tracks were stopped (0 = none reported; the edit-mode destroy still clears
-- any stopped-but-lingering tracks).
function RigWorkbench.purgeTracks(rig: Instance): number
	local controller = rig:FindFirstChildOfClass("Humanoid")
		or rig:FindFirstChildOfClass("AnimationController")
	if controller == nil then
		return 0
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if animator == nil then
		return 0
	end
	local count = 0
	local ok, tracks = pcall(function()
		return (animator :: Animator):GetPlayingAnimationTracks()
	end)
	if ok and type(tracks) == "table" then
		count = #tracks
		for _, t in tracks do
			pcall(function()
				t:Stop(0)
			end)
		end
	end
	if RunService:IsEdit() then
		-- Destroy even at count==0: stopped tracks no longer report as playing yet still linger + stamp.
		animator:Destroy()
	end
	return count
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
	-- TRACK GUARD (issue #23): a lingering track would re-stamp its pose over this write on applyPose.
	local purged = RigWorkbench.purgeTracks(rig)
	local rot = RigWorkbench.rotationCFrame(rx, ry, rz)
	local rid = beginRecording("Pose " .. m.Name)
	m.Transform = RigWorkbench.applyRotation(m.Transform, rot, relative)
	RigWorkbench.applyPose(rig)
	finishRecording(rid, true)
	redrawIfShown(rig)
	return string.format(
		"posed %s by (%g, %g, %g)%s%s",
		m.Name,
		rx,
		ry,
		rz,
		if relative then " [relative]" else " [absolute]",
		if purged > 0
			then string.format(" — stopped %d stale playing track(s) first", purged)
			else ""
	),
		true
end

-- Reset every joint's Transform to identity. (note, ok).
function RigWorkbench.resetPose(rig: Instance): (string, boolean)
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return "no joints to reset under " .. rig.Name, false
	end
	-- TRACK GUARD (issue #23): without the purge, applyPose lets a lingering track re-stamp its pose
	-- right over the identity reset ("reset didn't take" — the held-rig frozen-snapshot aggravator).
	local purged = RigWorkbench.purgeTracks(rig)
	local rid = beginRecording("Reset pose")
	for _, m in joints do
		m.Transform = CFrame.identity
	end
	RigWorkbench.applyPose(rig)
	finishRecording(rid, true)
	redrawIfShown(rig)
	return string.format(
		"reset %d joints on %s%s",
		#joints,
		rig.Name,
		if purged > 0
			then string.format(" — stopped %d stale playing track(s) first", purged)
			else ""
	),
		true
end

-- ---- spawn (delegates to NativeRig) ----

-- Spawn a native R15 rig. type "block" (default) = CreateHumanoidModelFromDescription; "avatar" = a mesh
-- character from a userId (default 1). Both build the Motor6Ds, sit on the baseplate, and anchor the root;
-- block also flat-colors each part. DEDUP (live bug 2026-07-10: every call stacked another "AgentRig"):
-- an existing workspace.AgentRig is REUSED by default (healed: attribute re-stamped, black
-- BodyColors/HumanoidDescription stripped on the block path); fresh=true destroys it and builds new;
-- duplicates beyond the first are destroyed either way. (Async/web — YIELDS.) Returns (model, note) or
-- (nil, errorNote).
-- Tools are ARTIFACTS, not rig parts: destroying a rig must never take an equipped Tool with it
-- (live-caught 2026-07-11: fresh=true destroyed the rig with the verified Sword still gripped —
-- the Tool and its authored clips died with the fixture). Evict to StarterPack before any destroy.
local function evictTools(rig: Model): number
	local evicted = 0
	for _, c in rig:GetChildren() do
		if c:IsA("Tool") then
			c.Parent = game:GetService("StarterPack")
			evicted += 1
		end
	end
	return evicted
end

function RigWorkbench.spawn(rigType: string, userId: number?, fresh: boolean?): (Instance?, string)
	local isAvatar = string.lower(rigType) == "avatar"
	local existing = NativeRig.findExisting()
	local destroyed = 0
	local evicted = 0
	for i = 2, #existing do
		evicted += evictTools(existing[i])
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
		if evicted > 0 then
			note ..= string.format(" — evicted %d equipped Tool(s) to StarterPack", evicted)
		end
		return kept, note
	end
	if kept ~= nil then
		evicted += evictTools(kept)
		kept:Destroy()
		destroyed += 1
	end
	local suffix = if destroyed > 0
		then string.format(" — destroyed %d pre-existing AgentRig(s)", destroyed)
		else ""
	if evicted > 0 then
		suffix ..= string.format(" — evicted %d equipped Tool(s) to StarterPack", evicted)
	end
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
