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

-- Wrap a DataModel mutation in an undoable ChangeHistory recording (edit only), like the rig tools.
local function recorded(label: string, fn: () -> (string, boolean)): (string, boolean)
	if not RunService:IsEdit() then
		return fn()
	end
	local rid = ChangeHistoryService:TryBeginRecording(label)
	local text, ok = fn()
	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if ok
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end
	return text, ok
end

local function runAdd(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "add_keyframe: " .. tostring(err), true
	end
	local clip = clipName(args)
	local time = if type(args.time) == "number"
		then args.time
		else AnimationClip.appendTime(rig, clip)
	local text, ok = recorded("Add keyframe", function()
		return AnimationClip.snapshotKeyframe(rig :: Instance, clip, time)
	end)
	return text, not ok
end

local function runList(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "list_clip: " .. tostring(err), true
	end
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
	-- Manual handoff (a SUCCESS, not an error): the clip is in AnimSaves, openable in the Animation Editor.
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
			.. "(default 'AgentClip'), time (seconds; omit to append after the last keyframe). Re-snapshots "
			.. "replace any keyframe already at that time. Then use capture_animation to SEE it.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
				time = {
					type = "number",
					description = "Keyframe time in seconds (omit = append).",
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
