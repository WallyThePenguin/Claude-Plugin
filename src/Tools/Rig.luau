--!strict
-- Rig tools: spawn_rig / get_rig / pose_joint / reset_pose / show_skeleton. Thin wrappers over the
-- stateless RigWorkbench module. DataModel edits (spawn/pose/reset) are destructive + undoable (relayed
-- in client-view like create_instance); reads + gizmo toggles are non-destructive. resolveRig: a dot
-- path, or the current Studio selection.

local Selection = game:GetService("Selection")

local RigWorkbench = require(script.Parent.Parent.RigWorkbench)
local Path = require(script.Parent.Path)

local Rig = {}

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

local function runSpawn(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local t = if type(args.type) == "string" then args.type else "r6"
	local assetId = if type(args.assetId) == "number" then args.assetId else nil
	local model, note = RigWorkbench.spawn(t, assetId)
	if model == nil then
		return note, true
	end
	return note .. " at " .. Path.fullPath(model), false
end

local function runGet(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "get_rig: " .. tostring(err), true
	end
	local text, names = RigWorkbench.readSkeleton(rig)
	if #names == 0 then
		return text, true
	end
	RigWorkbench.drawSkeleton(rig)
	return text .. "\n(skeleton gizmos drawn; show_skeleton {on:false} to hide)", false
end

local function runPose(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "pose_joint: " .. tostring(err), true
	end
	if type(args.joint) ~= "string" then
		return "pose_joint requires { rig?, joint = <string>, rotation = {x?,y?,z?}, relative? }",
			true
	end
	local rot = if type(args.rotation) == "table" then args.rotation else {}
	local rx = if type(rot.x) == "number" then rot.x else 0
	local ry = if type(rot.y) == "number" then rot.y else 0
	local rz = if type(rot.z) == "number" then rot.z else 0
	local relative = args.relative ~= false
	local note, ok = RigWorkbench.poseJoint(rig, args.joint, rx, ry, rz, relative)
	return note, not ok
end

local function runReset(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "reset_pose: " .. tostring(err), true
	end
	local note, ok = RigWorkbench.resetPose(rig)
	return note, not ok
end

local function runShow(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local on = args.on ~= false
	if not on then
		RigWorkbench.clearSkeleton()
		return "skeleton gizmos hidden.", false
	end
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "show_skeleton: " .. tostring(err), true
	end
	RigWorkbench.drawSkeleton(rig)
	return "skeleton gizmos drawn.", false
end

Rig.descriptors = {
	{
		name = "spawn_rig",
		description = "Spawn a PROGRAMMATIC rig to pose/animate — type 'r6' (default) or 'r15' (Motor6D, "
			.. "poseable). For the actual NATIVE Roblox rig, the user generates one via Avatar > Character "
			.. "(Rig Builder) and you operate on it with get_rig/pose_joint (they work on ANY Motor6D rig) "
			.. "— a plugin can't auto-spawn the native rig (LoadAsset is asset-trust-gated; no "
			.. "RigBuilderService). Optional assetId loads a rig the USER OWNS (a trusted published asset).",
		inputSchema = {
			type = "object",
			properties = {
				type = { type = "string", description = "'r6' (default) or 'r15'." },
				assetId = {
					type = "number",
					description = "Optional: load a rig YOU OWN by asset id (must be trusted for this place).",
				},
			},
		},
		destructive = true,
		run = runSpawn,
	},
	{
		name = "get_rig",
		description = "Read a rig's Motor6D SKELETON (joint names + which parts they connect + whether "
			.. "they're posed) and DRAW skeleton gizmos (a marker at each joint + bones). Input: rig "
			.. "(instance path; omit to use the selection). Use this to SEE the joints before posing.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
			},
		},
		destructive = false,
		run = runGet,
	},
	{
		name = "pose_joint",
		description = "Pose a rig by ROTATING one joint (sets Motor6D.Transform — the animation channel, "
			.. "live in edit). Input: rig (path or selection), joint (name from get_rig, e.g. "
			.. "'Right Shoulder' or 'RightElbow'), rotation {x,y,z} in DEGREES, relative (default true = "
			.. "add onto the current pose; false = absolute). Use camera_focus/orbit to see the result.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				joint = { type = "string", description = "Joint name (from get_rig)." },
				rotation = {
					type = "object",
					description = "Degrees: { x?, y?, z? } (missing axes = 0).",
					properties = {
						x = { type = "number" },
						y = { type = "number" },
						z = { type = "number" },
					},
				},
				relative = {
					type = "boolean",
					description = "Default true (accumulate). false = set absolute rotation.",
				},
			},
			required = { "joint" },
		},
		destructive = true,
		run = runPose,
	},
	{
		name = "reset_pose",
		description = "Reset a rig to its neutral pose (every joint's Transform back to identity). Input: "
			.. "rig (path or selection).",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
			},
		},
		destructive = true,
		run = runReset,
	},
	{
		name = "show_skeleton",
		description = "Toggle the skeleton gizmo overlay. Input: rig (path/selection) + on (default true; "
			.. "on:false hides the gizmos).",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				on = { type = "boolean", description = "true to draw (default), false to hide." },
			},
		},
		destructive = false,
		run = runShow,
	},
} :: { Descriptor }

return Rig
