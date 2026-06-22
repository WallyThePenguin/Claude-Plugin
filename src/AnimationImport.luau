--!strict
-- AnimationImport: retarget a SOURCE KeyframeSequence's poses onto a TARGET rig's Motor6D joints (by joint
-- NAME) and save the result as an editable clip under targetRig/AnimSaves/<clip>. The bridge between an
-- existing animation (fetched by asset id / resolved in-place by Tools/Import) and the agent's authoring
-- loop (list_clip / capture_animation / evaluate / export). v1 retarget = name match (R15->R15 clean);
-- unmatched source joints are dropped and reported via coverage. Reuses AnimationClip.buildPoseTree +
-- the AnimSaves storage convention.

local AnimationClip = require(script.Parent.AnimationClip)

local AnimationImport = {}

export type Coverage = { matched: number, total: number, droppedSource: { string } }

-- ---- pure (no DataModel -- unit-testable) ----

-- Retarget coverage: how many TARGET joints got a source pose (name match), and which SOURCE joint names
-- had no matching target (dropped -> a different skeleton). targetNames = the target rig's joint names;
-- sourceNames = the distinct joint names the source animates. droppedSource preserves source order, de-duped.
function AnimationImport.coverage(sourceNames: { string }, targetNames: { string }): Coverage
	local sourceSet: { [string]: boolean } = {}
	for _, n in ipairs(sourceNames) do
		sourceSet[n] = true
	end
	local targetSet: { [string]: boolean } = {}
	local total = 0
	for _, n in ipairs(targetNames) do
		if not targetSet[n] then
			targetSet[n] = true
			total += 1
		end
	end
	local matched = 0
	for n in targetSet do
		if sourceSet[n] then
			matched += 1
		end
	end
	local dropped: { string } = {}
	local seenDrop: { [string]: boolean } = {}
	for _, n in ipairs(sourceNames) do
		if not targetSet[n] and not seenDrop[n] then
			seenDrop[n] = true
			table.insert(dropped, n)
		end
	end
	return { matched = matched, total = total, droppedSource = dropped }
end

-- ---- impure (DataModel reads/writes) ----

-- { poseName -> CFrame } for every Pose in a keyframe (the joints it animates).
function AnimationImport.extractPoseMap(keyframe: Instance): { [string]: CFrame }
	local map: { [string]: CFrame } = {}
	for _, d in keyframe:GetDescendants() do
		if d:IsA("Pose") then
			map[(d :: Pose).Name] = (d :: Pose).CFrame
		end
	end
	return map
end

-- Distinct joint names the source animates (union of Pose.Name across all keyframes), source order.
function AnimationImport.sourceNames(sourceKS: KeyframeSequence): { string }
	local seen: { [string]: boolean } = {}
	local names: { string } = {}
	for _, kf in sourceKS:GetKeyframes() do
		for _, d in kf:GetDescendants() do
			if d:IsA("Pose") then
				local nm = (d :: Pose).Name
				if not seen[nm] then
					seen[nm] = true
					table.insert(names, nm)
				end
			end
		end
	end
	return names
end

-- The target rig's joint names (Motor6D Part1 child names -- what buildPoseTree poses).
function AnimationImport.targetJointNames(rig: Instance): { string }
	local names: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			local nm = (d.Part1 :: Instance).Name
			if not seen[nm] then
				seen[nm] = true
				table.insert(names, nm)
			end
		end
	end
	return names
end

-- Retarget all of sourceKS's keyframes onto targetRig by joint name, saving a FRESH clip under
-- targetRig/AnimSaves/<clipName> (a re-import overwrites). Returns (summary + coverage line, ok).
function AnimationImport.importInto(
	sourceKS: KeyframeSequence,
	targetRig: Instance,
	clipName: string
): (string, boolean)
	if AnimationClip.rigRoot(targetRig) == nil then
		return "no Motor6D rig under " .. targetRig.Name .. " (spawn_rig or select a rig).", false
	end
	local kfs = sourceKS:GetKeyframes()
	if #kfs == 0 then
		return "the source animation has no keyframes.", false
	end
	local ks = AnimationClip.getOrCreateClip(targetRig, clipName)
	for _, kf in ks:GetKeyframes() do
		kf:Destroy()
	end
	ks.Loop = sourceKS.Loop
	ks.Priority = sourceKS.Priority
	local entries: { { t: number, kf: Instance } } = {}
	for _, kf in kfs do
		table.insert(entries, { t = (kf :: Keyframe).Time, kf = kf })
	end
	table.sort(entries, function(a, b)
		return a.t < b.t
	end)
	for _, e in entries do
		local map = AnimationImport.extractPoseMap(e.kf)
		local pose = AnimationClip.buildPoseTree(targetRig, map)
		if pose ~= nil then
			local nkf = Instance.new("Keyframe")
			nkf.Time = AnimationClip.normalizeTime(e.t)
			pose.Parent = nkf
			ks:AddKeyframe(nkf)
		end
	end
	local cov = AnimationImport.coverage(
		AnimationImport.sourceNames(sourceKS),
		AnimationImport.targetJointNames(targetRig)
	)
	local covLine = string.format("retarget: matched %d/%d target joints", cov.matched, cov.total)
	if #cov.droppedSource > 0 then
		local shown: { string } = {}
		for i = 1, math.min(8, #cov.droppedSource) do
			table.insert(shown, cov.droppedSource[i])
		end
		local extra = if #cov.droppedSource > 8 then ", ..." else ""
		covLine = covLine
			.. string.format(
				"; %d source joint(s) had no target (dropped: %s%s)",
				#cov.droppedSource,
				table.concat(shown, ", "),
				extra
			)
	end
	return AnimationClip.summary(targetRig, clipName) .. "\n" .. covLine, true
end

return AnimationImport
