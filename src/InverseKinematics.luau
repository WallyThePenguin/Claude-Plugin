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

return IK
