--!strict
-- Animate tools: author + export an animation clip as a flip-book of keyposes. add_keyframe snapshots the
-- rig's CURRENT pose into rig/AnimSaves/<clip> (a KeyframeSequence, the Animation Editor's convention);
-- list_clip/remove_keyframe/clear_clip manage the timeline; export_animation tries a programmatic publish
-- and otherwise hands off to the Animation Editor. PREVIEW is capture_animation (Tools/Capture). Thin
-- wrappers over AnimationClip + resolveRig (path or selection). DataModel edits are undoable + relay in
-- client view (absent from Relay.LOCAL_TOOLS, like pose_joint).

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local AssetService = game:GetService("AssetService")

local AnimationClip = require(script.Parent.Parent.AnimationClip)
local Path = require(script.Parent.Path)

local Animate = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local DEFAULT_CLIP = "AgentClip"

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

local function clipName(args: any): string
	return if type(args.clip) == "string" and args.clip ~= "" then args.clip else DEFAULT_CLIP
end

-- Resolve the optional `scope` input to a list of CHILD-part names (or nil = key ALL joints). Accepts a
-- preset name ("rightArm"/"upperBody") or an explicit array of part names. Returns (names?, note, err?):
-- an unknown preset -> err; an empty/whitespace scope -> (nil, note) so add_keyframe falls back to all
-- joints with a heads-up.
local function resolveScope(scope: any): ({ string }?, string, string?)
	if scope == nil then
		return nil, "", nil
	end
	if type(scope) == "string" then
		if scope == "" then
			return nil, "", nil
		end
		local names, serr = AnimationClip.scopedJointSet(scope)
		if names == nil then
			return nil, "", serr
		end
		return names,
			"scope="
				.. scope
				.. " (keys only the scoped joints; the rest keep their own animation).",
			nil
	end
	if type(scope) == "table" then
		local list: { string } = {}
		for _, v in scope do
			if type(v) == "string" and v ~= "" then
				table.insert(list, v)
			end
		end
		if #list == 0 then
			return nil, "scope was empty — keyed ALL joints.", nil
		end
		return list, "scope=" .. tostring(#list) .. " explicit joint(s).", nil
	end
	return nil, "", nil
end

-- Wrap a DataModel mutation in an undoable ChangeHistory recording (edit only). Refuses if a recording
-- is already open (TryBeginRecording -> nil) rather than mutating inside an alien recording, matching the
-- structured writers (create_instance).
local function recorded(label: string, fn: () -> (string, boolean)): (string, boolean)
	if not RunService:IsEdit() then
		return fn()
	end
	local rid = ChangeHistoryService:TryBeginRecording(label)
	if rid == nil then
		return label .. ": a change recording is already in progress — try again.", true
	end
	local text, ok = fn()
	ChangeHistoryService:FinishRecording(
		rid,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	return text, ok
end

local function runAdd(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "add_keyframe: " .. tostring(err), true
	end
	local clip = clipName(args)
	local scopeNames, scopeNote, scopeErr = resolveScope(args.scope)
	if scopeErr ~= nil then
		return "add_keyframe: " .. scopeErr, true
	end
	local time = if type(args.time) == "number"
		then args.time
		else AnimationClip.appendTime(rig, clip)
	local text, ok = recorded("Add keyframe", function()
		return AnimationClip.snapshotKeyframe(rig :: Instance, clip, time, scopeNames)
	end)
	if scopeNote ~= "" then
		text = scopeNote .. "\n" .. text
	end
	return text, not ok
end

local function runList(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "list_clip: " .. tostring(err), true
	end
	-- An absent/empty clip is informational here (summary returns a friendly note), not an error.
	return AnimationClip.summary(rig, clipName(args)), false
end

local function runRemove(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "remove_keyframe: " .. tostring(err), true
	end
	if type(args.time) ~= "number" then
		return "remove_keyframe requires { rig?, clip?, time = <seconds> }", true
	end
	local text, ok = recorded("Remove keyframe", function()
		return AnimationClip.removeKeyframe(rig :: Instance, clipName(args), args.time)
	end)
	return text, not ok
end

local function runClear(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "clear_clip: " .. tostring(err), true
	end
	local text, ok = recorded("Clear clip", function()
		return AnimationClip.clearClip(rig :: Instance, clipName(args))
	end)
	return text, not ok
end

local function runExport(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "export_animation: " .. tostring(err), true
	end
	local clip = clipName(args)
	local ks = AnimationClip.findClip(rig, clip)
	if ks == nil or #ks:GetKeyframes() == 0 then
		return "export_animation: clip '" .. clip .. "' is empty or missing — add_keyframe first.",
			true
	end
	-- Try the in-Studio programmatic publish. As of 2026, CreateAssetAsync does NOT support Animation in
	-- Studio (Model/Plugin/Mesh/Image only), so this is EXPECTED to fail; we fall back to the manual
	-- Animation-Editor handoff. (Full Open Cloud export is a later slice.)
	local ok, result = pcall(function()
		return AssetService:CreateAssetAsync(ks, Enum.AssetType.Animation, {
			Name = clip,
			Description = "Authored by Studio Agent",
		})
	end)
	if ok and result ~= nil then
		return "export_animation: published '" .. clip .. "' -> " .. tostring(result) .. ".", false
	end
	-- Manual handoff (a SUCCESS, not an error): reached when CreateAssetAsync throws (the expected case) OR
	-- returns nil. The clip is in AnimSaves, openable in the Animation Editor.
	return "export_animation: programmatic animation publish isn't available in Studio yet, so the clip is "
		.. "saved at "
		.. rig:GetFullName()
		.. "/AnimSaves/"
		.. clip
		.. ". To publish: open Avatar > Animation Editor, select the rig, load '"
		.. clip
		.. "', then Publish. (Automated Open Cloud export is a planned follow-up.)",
		false
end

Animate.descriptors = {
	{
		name = "add_keyframe",
		description = "Author an animation by SNAPSHOTTING the rig's current pose as a keyframe. Pose the "
			.. "rig first (pose_joint / ik_reach), then call this to capture that pose at `time` seconds "
			.. "into a clip (a KeyframeSequence saved under rig/AnimSaves/<clip>, the Animation Editor's "
			.. "folder). Repeat per keypose to build the motion. Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip'), time (seconds; omit to append after the last keyframe), scope "
			.. "(optional — keys only a subset of joints: 'rightArm' for an item swing/use clip so the "
			.. "legs/torso keep their own animation, 'upperBody', or an array of joint child-part names; "
			.. "omit for a full-body clip). Re-snapshots replace any keyframe already at that time. Then "
			.. "use capture_animation to SEE it.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
				time = {
					type = "number",
					description = "Keyframe time in seconds (omit = append).",
				},
				scope = {
					description = "Joint scope: 'rightArm' (key only the right-arm chain — use for "
						.. "item swing/use clips so the legs/torso keep their own animation), 'upperBody', "
						.. "or an array of joint child-part names. Omit to key ALL joints (full-body).",
				},
			},
		},
		destructive = true,
		run = runAdd,
	},
	{
		name = "list_clip",
		description = "Show an animation clip's timeline: each keyframe's time + how many joints are posed "
			.. "there, plus the clip length, loop, and priority. Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip').",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
			},
		},
		destructive = false,
		run = runList,
	},
	{
		name = "remove_keyframe",
		description = "Remove the keyframe nearest `time` from a clip. Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip'), time (seconds, required).",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
				time = {
					type = "number",
					description = "Time (seconds) of the keyframe to remove.",
				},
			},
			required = { "time" },
		},
		destructive = true,
		run = runRemove,
	},
	{
		name = "clear_clip",
		description = "Remove ALL keyframes from a clip (keeps the empty clip). Inputs: rig (path or "
			.. "selection), clip (default 'AgentClip').",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
			},
		},
		destructive = true,
		run = runClear,
	},
	{
		name = "export_animation",
		description = "Publish an authored clip. Programmatic animation upload isn't available in Studio "
			.. "yet, so today this saves the clip in rig/AnimSaves and hands off to the Animation Editor "
			.. "(open it, select the rig, load the clip, Publish). Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip').",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
			},
		},
		destructive = false,
		run = runExport,
	},
} :: { Descriptor }

return Animate
