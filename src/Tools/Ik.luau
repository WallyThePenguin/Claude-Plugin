--!strict
-- IK tool: ik_reach. Thin wrapper over the stateless InverseKinematics + IkChains modules. A DataModel
-- edit (writes Motor6D.Transform) -> destructive + undoable + relayed in client-view (NOT in
-- Relay.LOCAL_TOOLS). resolveRig: a dot path, or the current Studio selection (like Tools/Rig.luau).

local Selection = game:GetService("Selection")

local InverseKinematics = require(script.Parent.Parent.InverseKinematics)
local IkChains = require(script.Parent.Parent.IkChains)
local Path = require(script.Parent.Path)

local Ik = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function resolveRig(target: any): (Instance?, string?)
	if type(target) == "string" and target ~= "" then
		return Path.resolve(target)
	end
	local sel = Selection:Get()
	if #sel > 0 then
		return sel[1], nil
	end
	return nil, "no rig given and nothing selected — pass a rig path or select the rig."
end

local function vec(t: any): Vector3?
	if type(t) ~= "table" then
		return nil
	end
	local hasX, hasY, hasZ = type(t.x) == "number", type(t.y) == "number", type(t.z) == "number"
	if not (hasX or hasY or hasZ) then
		-- an empty/garbage object is NOT a valid point — report it rather than silently using origin.
		return nil
	end
	return Vector3.new(if hasX then t.x else 0, if hasY then t.y else 0, if hasZ then t.z else 0)
end

local function runReach(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "ik_reach: " .. tostring(err), true
	end

	local resolved, rerr = IkChains.resolveChain(rig, {
		chain = if type(args.chain) == "string" then args.chain else nil,
		effector = if type(args.effector) == "string" then args.effector else nil,
		chainRoot = if type(args.chainRoot) == "string" then args.chainRoot else nil,
	})
	if resolved == nil then
		return "ik_reach: " .. tostring(rerr), true
	end

	-- target: world point OR a part path
	local targetPos: Vector3?
	if type(args.targetPart) == "string" and args.targetPart ~= "" then
		local part, perr = Path.resolve(args.targetPart)
		if part == nil then
			return "ik_reach targetPart: " .. tostring(perr), true
		end
		if not part:IsA("BasePart") then
			return "ik_reach targetPart must be a BasePart, got " .. part.ClassName, true
		end
		targetPos = part.Position
	else
		targetPos = vec(args.target)
	end
	if targetPos == nil then
		return "ik_reach needs target = {x,y,z} OR targetPart = <path to a BasePart>", true
	end

	local pole = vec(args.pole)
	local clamped, residual = InverseKinematics.reach(rig, resolved, targetPos, pole)

	local names: { string } = {}
	for _, m in resolved.posedJoints do
		table.insert(names, m.Name)
	end
	local note = string.format(
		"ik_reach: posed %s [%s] -> (%.1f, %.1f, %.1f); residual %.2f studs%s",
		resolved.effectorPart.Name,
		table.concat(names, ", "),
		targetPos.X,
		targetPos.Y,
		targetPos.Z,
		residual,
		if clamped then " (target out of reach — limb straightened)" else ""
	)
	return note, false
end

Ik.descriptors = {
	{
		name = "ik_reach",
		description = "INVERSE KINEMATICS: pose a rig so a limb's end reaches a point. Give a chain + a "
			.. "target and the solver rotates the whole chain (sets Motor6D.Transform, live in edit) — you "
			.. "don't compute joint angles. chain = a preset: RightArm / LeftArm / RightLeg / LeftLeg / "
			.. "Spine (R6+R15 aware); OR effector + chainRoot joint names for a custom rig. target = "
			.. "{x,y,z} world point, OR targetPart = a path to a part to reach toward. pole = optional "
			.. "{x,y,z} the elbow/knee points toward. Out-of-reach targets straighten the limb. Use "
			.. "get_rig to see joints and camera_focus/camera_orbit to inspect the result.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				chain = {
					type = "string",
					description = "Preset: RightArm, LeftArm, RightLeg, LeftLeg, or Spine.",
				},
				effector = {
					type = "string",
					description = "Custom chains: the tip joint name (use with chainRoot instead of chain).",
				},
				chainRoot = {
					type = "string",
					description = "Custom chains: the root joint name (an ancestor of effector).",
				},
				target = {
					type = "object",
					description = "World point to reach: { x, y, z }.",
					properties = {
						x = { type = "number" },
						y = { type = "number" },
						z = { type = "number" },
					},
				},
				targetPart = {
					type = "string",
					description = "Path to a BasePart to reach toward (alternative to target).",
				},
				pole = {
					type = "object",
					description = "Optional world point the elbow/knee points toward: { x, y, z }.",
					properties = {
						x = { type = "number" },
						y = { type = "number" },
						z = { type = "number" },
					},
				},
			},
		},
		destructive = true,
		run = runReach,
	},
} :: { Descriptor }

return Ik
