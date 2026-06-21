--!strict
-- InverseKinematics: PURE IK solver for Motor6D chains. All math operates on an anchor CFrame + a list
-- of {c0, c1} joint offsets (the static rig data) + a list of per-joint Transforms — no DataModel reads,
-- so it is fully unit-testable and never depends on the engine resolving joints synchronously within one
-- tool call. The thin `reach` method (added later) marshals a real rig's Motor6Ds into these pure calls
-- and writes the result to Motor6D.Transform (the channel slice A poses live in edit) inside a
-- ChangeHistory recording. Hybrid: analytic 2-bone for limbs (pole vector), CCD for spine / R6
-- single-joint / custom chains.

local IK = {}

export type Link = { c0: CFrame, c1: CFrame }
export type Solve2Bone =
	{ elbowPos: Vector3, upperDir: Vector3, lowerDir: Vector3, clamped: boolean }

local EPS = 1e-4

-- World rotation CFrame that maps direction a onto direction b (about the origin). Identity if either is
-- degenerate or already aligned; a 180-degree flip about an arbitrary perpendicular when opposed.
function IK.rotationBetween(a: Vector3, b: Vector3): CFrame
	if a.Magnitude < 1e-6 or b.Magnitude < 1e-6 then
		return CFrame.identity
	end
	local ua, ub = a.Unit, b.Unit
	local dot = math.clamp(ua:Dot(ub), -1, 1)
	if dot > 0.999999 then
		return CFrame.identity
	end
	if dot < -0.999999 then
		local axis = ua:Cross(Vector3.new(1, 0, 0))
		if axis.Magnitude < 1e-3 then
			axis = ua:Cross(Vector3.new(0, 1, 0))
		end
		return CFrame.fromAxisAngle(axis.Unit, math.pi)
	end
	return CFrame.fromAxisAngle(ua:Cross(ub).Unit, math.acos(dot))
end

-- The local-frame Transform that, right-multiplied onto restFrame, rotates the sub-chain by worldRot
-- about the joint pivot. To compose onto an existing transform: TFR(restFrame, worldRot) * oldTransform.
function IK.transformForRotation(restFrame: CFrame, worldRot: CFrame): CFrame
	local r = restFrame.Rotation
	return r:Inverse() * worldRot * r
end

-- Forward kinematics. Returns the PRE-transform world frame of every joint (Part0World*c0, with the
-- transforms of joints ABOVE it applied but its own transform NOT) and the final effector part world
-- (last link's Part1). anchorCF = links[1]'s Part0 world.
function IK.forwardFrames(
	anchorCF: CFrame,
	links: { Link },
	transforms: { CFrame }
): ({ CFrame }, CFrame)
	local preFrames: { CFrame } = table.create(#links)
	local part0World = anchorCF
	for i, link in links do
		local jointFrame = part0World * link.c0
		preFrames[i] = jointFrame
		local t = transforms[i] or CFrame.identity
		part0World = (jointFrame * t) * link.c1:Inverse()
	end
	return preFrames, part0World
end

-- Geometric 2-bone solve in world space. Returns the elbow position, the upper/lower bone directions,
-- and whether the target was clamped to the reachable range. l1 = root->mid, l2 = mid->effector.
function IK.solve2Bone(
	rootPos: Vector3,
	l1: number,
	l2: number,
	targetPos: Vector3,
	poleHint: Vector3
): Solve2Bone
	local toTarget = targetPos - rootPos
	local dist = toTarget.Magnitude
	local clamped = false
	local minReach = math.abs(l1 - l2) + 1e-3
	local maxReach = l1 + l2 - 1e-3
	local d = dist
	if d < minReach then
		d, clamped = minReach, true
	elseif d > maxReach then
		d, clamped = maxReach, true
	end
	local dir = if dist > EPS then toTarget.Unit else Vector3.new(0, -1, 0)
	local clampedTarget = rootPos + dir * d
	-- angle at the root between the upper bone and the line to the (clamped) target
	local cosA = math.clamp((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1, 1)
	local a = math.acos(cosA)
	-- in-plane perpendicular to dir, pointing toward the pole (decides elbow/knee direction)
	local poleVec = poleHint - rootPos
	local perp = poleVec - dir * poleVec:Dot(dir)
	if perp.Magnitude < EPS then
		perp = dir:Cross(Vector3.new(0, 1, 0))
		if perp.Magnitude < EPS then
			perp = dir:Cross(Vector3.new(1, 0, 0))
		end
	end
	perp = perp.Unit
	local upperDir = (dir * math.cos(a) + perp * math.sin(a)).Unit
	local elbowPos = rootPos + upperDir * l1
	local lowerVec = clampedTarget - elbowPos
	local lowerDir = if lowerVec.Magnitude > EPS then lowerVec.Unit else dir
	return { elbowPos = elbowPos, upperDir = upperDir, lowerDir = lowerDir, clamped = clamped }
end

-- Solve a 2-bone limb and return the Transforms for the FIRST TWO links (shoulder, elbow). `links` may
-- include a trailing terminal joint (e.g. the wrist) used only to locate the effector part — it is kept
-- at identity. Root-first: solve the upper bone, recompute the elbow frame via FK, then the lower bone.
function IK.solve2BoneTransforms(
	anchorCF: CFrame,
	links: { Link },
	targetPos: Vector3,
	poleHint: Vector3
): ({ CFrame }, boolean)
	local identityT: { CFrame } = table.create(#links, CFrame.identity)
	local restFrames, effectorRest = IK.forwardFrames(anchorCF, links, identityT)
	local rootPos = restFrames[1].Position
	local elbowRestPos = restFrames[2].Position
	local l1 = (elbowRestPos - rootPos).Magnitude
	local l2 = (effectorRest.Position - elbowRestPos).Magnitude
	local restUpperDir = (elbowRestPos - rootPos).Unit
	local solve = IK.solve2Bone(rootPos, l1, l2, targetPos, poleHint)

	local worldRotUpper = IK.rotationBetween(restUpperDir, solve.upperDir)
	local t1 = IK.transformForRotation(restFrames[1], worldRotUpper)

	local afterT1: { CFrame } = table.clone(identityT)
	afterT1[1] = t1
	local frames2, effector2 = IK.forwardFrames(anchorCF, links, afterT1)
	local elbowPos2 = frames2[2].Position
	local currentLowerDir = (effector2.Position - elbowPos2).Unit
	local worldRotLower = IK.rotationBetween(currentLowerDir, solve.lowerDir)
	local t2 = IK.transformForRotation(frames2[2], worldRotLower)

	return { t1, t2 }, solve.clamped
end

return IK
