--!strict
-- AnimationClip: the animation engine core. Author a clip as a flip-book of keyposes -- snapshot the
-- rig's current Motor6D.Transform per joint into a Keyframe (a nested Pose tree mirroring the Motor6D
-- graph), accumulate keyframes in a KeyframeSequence stored under rig/AnimSaves/<clipName> (the official
-- Animation Editor's folder convention, so the human can refine the agent's clip there). PREVIEW lives in
-- Tools/Capture (register -> play -> scrub StepAnimations). STATELESS: operates on rigs/clips in the
-- DataModel. Proven live (the spike): ks:AddKeyframe (NOT bare .Parent) is required for the clip length to
-- register; RegisterKeyframeSequence -> a local content-hash id (no upload).

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local AnimationClip = {}

local ANIMSAVES = "AnimSaves"
local TIME_EPSILON = 1e-3 -- keyframes within this many seconds share a time slot
local DEFAULT_GAP = 0.5 -- append-time gap when add_keyframe is given no time

-- ---- pure helpers (unit-tested) ----

-- Round a time to the millisecond and clamp to >= 0 (the keyframe time-slot key). NaN -> 0.
function AnimationClip.normalizeTime(t: number): number
	if t ~= t or t < 0 then
		return 0
	end
	return math.floor(t * 1000 + 0.5) / 1000
end

-- Part0 -> { Motor6D } adjacency (walk the joint graph root->leaf).
function AnimationClip.adjacency(rig: Instance): { [Instance]: { Motor6D } }
	local childrenOf: { [Instance]: { Motor6D } } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			local p0 = d.Part0 :: Instance
			local list = childrenOf[p0]
			if list == nil then
				list = {}
				childrenOf[p0] = list
			end
			table.insert(list, d)
		end
	end
	return childrenOf
end

-- The rig's root part: HumanoidRootPart if present, else the Part0 that is never any Motor6D's Part1.
function AnimationClip.rigRoot(rig: Instance): Instance?
	local hrp = rig:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil then
		return hrp
	end
	local isChild: { [Instance]: boolean } = {}
	local part0s: { [Instance]: boolean } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			isChild[d.Part1 :: Instance] = true
			part0s[d.Part0 :: Instance] = true
		end
	end
	for p in part0s do
		if not isChild[p] then
			return p
		end
	end
	return nil
end

-- Build the nested Pose tree for one keyframe. Pose.Name = the CHILD part name; Pose.CFrame =
-- transformsMap[childName] (the joint's Motor6D.Transform) or identity. The root part's pose is identity
-- (it drives no joint). Returns the root Pose (parent it to a Keyframe), or nil if there is no rig root.
function AnimationClip.buildPoseTree(rig: Instance, transformsMap: { [string]: CFrame }): Instance?
	local childrenOf = AnimationClip.adjacency(rig)
	local root = AnimationClip.rigRoot(rig)
	if root == nil then
		return nil
	end
	local visited: { [Instance]: boolean } = {}
	local function makePose(part: Instance): Instance
		visited[part] = true
		local pose = Instance.new("Pose")
		pose.Name = part.Name
		pose.CFrame = transformsMap[part.Name] or CFrame.identity
		pose.EasingStyle = Enum.PoseEasingStyle.Linear
		for _, m in (childrenOf[part] or {}) do
			local child = (m :: Motor6D).Part1 :: Instance
			if not visited[child] then
				makePose(child).Parent = pose
			end
		end
		return pose
	end
	return makePose(root)
end

-- ---- joint scoping (arm-only / partial-body authoring) ----

-- A joint-scope preset -> the CHILD-part names a clip should drive (Pose.Name keys). For item use-anims,
-- "rightArm" keys ONLY the right-arm chain, so an Action-priority swing overrides just the arm while
-- lower-priority locomotion drives the unkeyed legs/torso. "upperBody" adds the left arm, torso twist,
-- and head. Returns (names, nil) or (nil, err) for an unknown preset. PURE -> unit-tested.
local SCOPE_PRESETS: { [string]: { string } } = {
	rightArm = { "RightUpperArm", "RightLowerArm", "RightHand", "Head" },
	upperBody = {
		"RightUpperArm",
		"RightLowerArm",
		"RightHand",
		"LeftUpperArm",
		"LeftLowerArm",
		"LeftHand",
		"UpperTorso",
		"Head",
	},
}

function AnimationClip.scopedJointSet(preset: string): ({ string }?, string?)
	local names = SCOPE_PRESETS[preset]
	if names == nil then
		local known: { string } = {}
		for k in SCOPE_PRESETS do
			table.insert(known, k)
		end
		table.sort(known)
		return nil,
			"unknown scope preset '" .. tostring(preset) .. "' (presets: " .. table.concat(
				known,
				", "
			) .. ")"
	end
	-- return a copy so a caller can't mutate the shared preset table
	local out: { string } = {}
	for _, n in names do
		table.insert(out, n)
	end
	return out, nil
end

-- Build the Poses for a SCOPED clip: the scoped CHILD-parts PLUS their ancestor "carriers" back to the
-- rig root, nested as a tree; sibling branches (the legs, the other arm) are pruned. The carrier chain is
-- REQUIRED -- the Animator only applies a Pose that is nested under the root chain (a top-level pose is
-- ignored by RegisterKeyframeSequence playback). Carriers sit at their captured transform (identity at
-- rest), which holds the torso upright; the scoped joints (e.g. the arm + Head) carry the motion -- keying
-- the Head level is what keeps the head from over-rotating while the torso is held upright. Returns the
-- top-level Pose(s) for the caller to parent to the Keyframe (normally one: the rig root).
function AnimationClip.buildScopedPoses(
	rig: Instance,
	transformsMap: { [string]: CFrame },
	scopeNames: { string }
): { Instance }
	local scopeSet: { [string]: boolean } = {}
	for _, n in scopeNames do
		scopeSet[n] = true
	end
	-- child-part name -> parent-part name
	local parentOf: { [string]: string } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			parentOf[(d.Part1 :: Instance).Name] = (d.Part0 :: Instance).Name
		end
	end
	-- include = the scoped parts that exist, plus every ancestor up to the root (the carriers)
	local include: { [string]: boolean } = {}
	for name in scopeSet do
		if parentOf[name] ~= nil or scopeSet[name] then
			-- walk up from the scoped part adding it + each ancestor (a part with no parent entry is a
			-- root and is still added by the first iteration)
			local cur: string? = name
			while cur ~= nil and not include[cur] do
				include[cur] = true
				cur = parentOf[cur]
			end
		end
	end
	-- create a Pose for each included part, then nest each under its parent's pose (or collect as a top)
	local poseByName: { [string]: Instance } = {}
	for name in include do
		local pose = Instance.new("Pose")
		pose.Name = name
		pose.CFrame = transformsMap[name] or CFrame.identity
		pose.EasingStyle = Enum.PoseEasingStyle.Linear
		poseByName[name] = pose
	end
	local tops: { Instance } = {}
	for name, pose in poseByName do
		local parentName = parentOf[name]
		if parentName ~= nil and poseByName[parentName] ~= nil then
			pose.Parent = poseByName[parentName]
		else
			table.insert(tops, pose)
		end
	end
	return tops
end

-- ---- clip storage (rig/AnimSaves/<clipName> -- the Animation Editor convention) ----

local function animSaves(rig: Instance): Folder
	local f = rig:FindFirstChild(ANIMSAVES)
	if f ~= nil and f:IsA("Folder") then
		return f :: Folder
	end
	local nf = Instance.new("Folder")
	nf.Name = ANIMSAVES
	nf.Parent = rig
	return nf
end

function AnimationClip.getOrCreateClip(rig: Instance, clipName: string): KeyframeSequence
	local folder = animSaves(rig)
	local existing = folder:FindFirstChild(clipName)
	if existing ~= nil and existing:IsA("KeyframeSequence") then
		return existing :: KeyframeSequence
	end
	local ks = Instance.new("KeyframeSequence")
	ks.Name = clipName
	ks.Loop = false
	ks.Priority = Enum.AnimationPriority.Action
	ks.Parent = folder
	return ks
end

function AnimationClip.findClip(rig: Instance, clipName: string): KeyframeSequence?
	local folder = rig:FindFirstChild(ANIMSAVES)
	if folder == nil then
		return nil
	end
	local existing = folder:FindFirstChild(clipName)
	if existing ~= nil and existing:IsA("KeyframeSequence") then
		return existing :: KeyframeSequence
	end
	return nil
end

-- The rig's current Motor6D.Transform per joint, keyed by the CHILD part name (matches Pose.Name).
-- Guards BOTH Part0 and Part1 (a joint with a nil Part0 is degenerate — its Transform is meaningless).
function AnimationClip.currentTransforms(rig: Instance): { [string]: CFrame }
	local map: { [string]: CFrame } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			map[(d.Part1 :: Instance).Name] = d.Transform
		end
	end
	return map
end

-- ---- timeline read helpers ----

local function sortedTimes(ks: KeyframeSequence): { number }
	local times: { number } = {}
	for _, kf in ks:GetKeyframes() do
		table.insert(times, kf.Time)
	end
	table.sort(times)
	return times
end

-- How many joints are actively posed in a keyframe (Pose.CFrame ~= identity). The root/unposed joints
-- carry identity poses; we built them from Motor6D.Transform, which is identity at rest, so this reads as
-- "joints moved from rest" -- a display heuristic, not an exact-equality contract.
local function posedCount(kf: Keyframe): number
	local n = 0
	for _, d in kf:GetDescendants() do
		if d:IsA("Pose") and d.CFrame ~= CFrame.identity then
			n += 1
		end
	end
	return n
end

-- One-line-per-keyframe summary of a clip.
function AnimationClip.summary(rig: Instance, clipName: string): string
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return "no clip '"
			.. clipName
			.. "' under "
			.. rig.Name
			.. "/"
			.. ANIMSAVES
			.. " (add_keyframe first)."
	end
	local kfs = ks:GetKeyframes()
	if #kfs == 0 then
		return clipName .. ": empty (0 keyframes). Pose the rig, then add_keyframe."
	end
	-- Pair each keyframe with its time and sort by time. (Don't key a map by the float time -- two
	-- keyframes sharing a millisecond slot would collide and one would be dropped from the summary.)
	local entries: { { t: number, kf: Keyframe } } = {}
	for _, kf in kfs do
		table.insert(entries, { t = kf.Time, kf = kf })
	end
	table.sort(entries, function(a, b)
		return a.t < b.t
	end)
	local length = entries[#entries].t
	local lines: { string } = {
		string.format(
			"%s: %d keyframes, length %.3fs, loop=%s, priority=%s",
			clipName,
			#kfs,
			length,
			tostring(ks.Loop),
			ks.Priority.Name
		),
	}
	for _, e in entries do
		table.insert(lines, string.format("  t=%.3fs: %d posed joints", e.t, posedCount(e.kf)))
	end
	return table.concat(lines, "\n")
end

-- ---- mutations (the tool wraps these in a ChangeHistory recording) ----

-- Snapshot the rig's CURRENT pose into the clip at `time` (replacing any keyframe at that time slot).
-- `scopeNames` (optional): a list of CHILD-part names to key -- when given (non-empty), the keyframe gets
-- Poses ONLY for those joints (see buildScopedPoses), so the clip drives only the scoped joints (arm-only
-- / partial-body); ancestor carriers are omitted. nil/empty = key all joints (full body). If the scope
-- matches no joints on the rig, falls back to a full-body snapshot.
function AnimationClip.snapshotKeyframe(
	rig: Instance,
	clipName: string,
	time: number,
	scopeNames: { string }?
): (string, boolean)
	if AnimationClip.rigRoot(rig) == nil then
		return "no Motor6D rig found under " .. rig.Name .. " (spawn_rig or select a rig).", false
	end
	local t = AnimationClip.normalizeTime(time)
	local ks = AnimationClip.getOrCreateClip(rig, clipName)
	for _, kf in ks:GetKeyframes() do
		if math.abs(kf.Time - t) <= TIME_EPSILON then
			kf:Destroy()
		end
	end
	local transforms = AnimationClip.currentTransforms(rig)
	local kf = Instance.new("Keyframe")
	kf.Time = t
	local scopedPoses: { Instance } = {}
	if scopeNames ~= nil and #scopeNames > 0 then
		scopedPoses = AnimationClip.buildScopedPoses(rig, transforms, scopeNames)
	end
	if #scopedPoses > 0 then
		for _, pose in scopedPoses do
			pose.Parent = kf
		end
	else
		-- full-body (no scope, or the scope matched nothing on this rig)
		local root = AnimationClip.buildPoseTree(rig, transforms)
		if root == nil then
			kf:Destroy()
			return "could not build a pose for " .. rig.Name, false
		end
		root.Parent = kf
	end
	ks:AddKeyframe(kf) -- AddKeyframe, NOT bare .Parent (the spike: bare .Parent leaves length=0)
	return AnimationClip.summary(rig, clipName), true
end

-- Remove the keyframe nearest `time`. Returns (text, ok).
function AnimationClip.removeKeyframe(
	rig: Instance,
	clipName: string,
	time: number
): (string, boolean)
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return "no clip '" .. clipName .. "' to edit under " .. rig.Name, false
	end
	local t = AnimationClip.normalizeTime(time)
	local target: Keyframe? = nil
	local best = math.huge
	for _, kf in ks:GetKeyframes() do
		local d = math.abs(kf.Time - t)
		if d < best then
			best = d
			target = kf
		end
	end
	if target == nil then
		return clipName .. " has no keyframes to remove.", false
	end
	local removedAt = target.Time
	target:Destroy()
	return string.format(
		"removed keyframe at t=%.3fs from %s.\n%s",
		removedAt,
		clipName,
		AnimationClip.summary(rig, clipName)
	),
		true
end

-- Remove all keyframes (keeps the empty KeyframeSequence). Returns (text, ok).
function AnimationClip.clearClip(rig: Instance, clipName: string): (string, boolean)
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return "no clip '" .. clipName .. "' to clear under " .. rig.Name, false
	end
	local n = 0
	-- GetKeyframes() returns a snapshot array (not a live view), so destroying inside the loop is safe.
	for _, kf in ks:GetKeyframes() do
		kf:Destroy()
		n += 1
	end
	return string.format("cleared %d keyframes from %s.", n, clipName), true
end

-- Register the clip locally -> a content-hash AnimationId (no upload). (id, nil) or (nil, err).
function AnimationClip.register(ks: KeyframeSequence): (string?, string?)
	local ok, id = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(ks)
	end)
	if not ok or type(id) ~= "string" then
		return nil, "RegisterKeyframeSequence failed: " .. tostring(id)
	end
	return id, nil
end

-- The append time for a new keyframe: last keyframe time + DEFAULT_GAP (0 for the first).
function AnimationClip.appendTime(rig: Instance, clipName: string): number
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return 0
	end
	local times = sortedTimes(ks)
	if #times == 0 then
		return 0
	end
	return AnimationClip.normalizeTime(times[#times] + DEFAULT_GAP)
end

return AnimationClip
