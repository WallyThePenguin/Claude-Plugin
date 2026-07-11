--!strict
-- Animate tools: author + export an animation clip as a flip-book of keyposes. add_keyframe snapshots the
-- rig's CURRENT pose into rig/AnimSaves/<clip> (a KeyframeSequence, the Animation Editor's convention);
-- list_clip/remove_keyframe/clear_clip manage the timeline; export_animation tries a programmatic publish
-- and otherwise hands off to the Animation Editor. PREVIEW is capture_animation (Tools/Capture). Thin
-- wrappers over AnimationClip + resolveRig (path or selection). DataModel edits are undoable + relay in
-- client view (absent from Relay.LOCAL_TOOLS, like pose_joint).
-- HONESTY (issue #23): add_keyframe purges lingering AnimationTracks first (they re-stamp their pose
-- into Motor6D.Transform on every StepAnimations, freezing snapshots) and READS BACK every batch-posed
-- joint after apply — a >2 deg mismatch errors loudly and refuses the keyframe instead of keying a lie.

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local AssetService = game:GetService("AssetService")

local AnimationClip = require(script.Parent.Parent.AnimationClip)
local RigWorkbench = require(script.Parent.Parent.RigWorkbench)
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

-- Verify-after-apply tolerance (issue #23): a posed joint must read back within this many degrees of
-- the request or the keyframe is REFUSED (silent frozen-snapshot lies become loud errors).
local VERIFY_TOLERANCE_DEG = 2

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
	return nil, "", "scope must be a string preset or an array of joint names, got " .. type(scope)
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
	-- WEAPON channel (SP2c): weapon=true keys the equipped tool's Handle too (Pose named after the
	-- AgentEditGrip joint's Part1, nested under RightHand — the Animator matches by connected-part
	-- names). Full-body snapshots already include it; a scope must have it appended explicitly.
	if args.weapon == true then
		local wnames = AnimationClip.weaponChildNames(rig :: Instance)
		if #wnames == 0 then
			return "add_keyframe: weapon=true but no AgentEditGrip Motor6D under "
				.. (rig :: Instance).Name
				.. " — equip a Tool with grip_tool first (the grip joint IS the weapon channel).",
				true
		end
		if scopeNames ~= nil then
			local have: { [string]: boolean } = {}
			for _, n in scopeNames do
				have[n] = true
			end
			for _, n in wnames do
				if not have[n] then
					table.insert(scopeNames, n)
				end
			end
		end
		local wNote = "weapon channel: " .. table.concat(wnames, ", ") .. (if scopeNames ~= nil
			then " added to scope."
			else " (full-body snapshot keys it already).")
		scopeNote = if scopeNote ~= "" then scopeNote .. " " .. wNote else wNote
	end
	-- BATCH KEYPOSE: the optional `poses` map poses N joints THEN snapshots — ONE tool call per keypose
	-- (the capped factory transcript spent ~65% of its 114 tool calls on pose_joint-per-joint-per-keypose;
	-- this collapses pose_joint xN + add_keyframe into one call). All-or-nothing: parse the map + resolve
	-- EVERY joint (RigWorkbench.findJoint — pose_joint's resolver) BEFORE mutating; unknown names error
	-- listing the bad ones. Rotations apply ABSOLUTE (pose_joint relative=false semantics): a keypose is a
	-- complete statement, so an all-zeros entry returns that joint to neutral (no reset_pose needed).
	local poseEntries: { AnimationClip.PoseEntry } = {}
	local poseJoints: { Motor6D } = {}
	if args.poses ~= nil then
		local entries, perr = AnimationClip.parsePoseBatch(args.poses)
		if entries == nil then
			return "add_keyframe: " .. tostring(perr), true
		end
		local bad: { string } = {}
		for _, e in entries do
			local m = RigWorkbench.findJoint(rig :: Instance, e.name)
			if m == nil then
				table.insert(bad, e.name)
			else
				table.insert(poseJoints, m)
			end
		end
		if #bad > 0 then
			return "add_keyframe: unknown joint(s) in poses: "
				.. table.concat(bad, ", ")
				.. " — nothing was posed or keyed (get_rig lists the joint names).",
				true
		end
		poseEntries = entries
	end
	local time = if type(args.time) == "number"
		then args.time
		else AnimationClip.appendTime(rig, clip)
	-- TRACK GUARD (issue #23 add-keyframe-batch-frozen-snapshot + banked doctrine: every authoring path
	-- purges playing tracks first). CHANNEL FACTS, resolved by reading the code: the batch WRITES
	-- Motor6D.Transform and the snapshot READS Motor6D.Transform (AnimationClip.currentTransforms) —
	-- the same channel, no C0 on either side. The frozen snapshot happened because StepAnimations
	-- (applyPose) re-stamps every loaded AnimationTrack's pose into Motor6D.Transform BETWEEN the
	-- batch's write and the snapshot's read — and a track lingers in edit even after Stop() (only
	-- destroying the Animator removes it; live-verified in capture_animation). Purge BEFORE the
	-- recording so a verify-fail cancel can't resurrect the animator with its tracks.
	local purged = RigWorkbench.purgeTracks(rig :: Instance)
	local posedApplied = false
	local text, ok = recorded("Add keyframe", function()
		-- Pose the batch INSIDE the recording (a cancel rolls the rig back too), then snapshot as today.
		for i, e in poseEntries do
			local m = poseJoints[i]
			m.Transform = RigWorkbench.applyRotation(
				m.Transform,
				RigWorkbench.rotationCFrame(e.x, e.y, e.z),
				false -- absolute: each entry IS the keypose
			)
		end
		if #poseEntries > 0 then
			RigWorkbench.applyPose(rig :: Instance) -- one StepAnimations for the whole batch
			posedApplied = true
			-- VERIFY-AFTER-APPLY (the honesty fix, issue #23): read back each posed joint's EFFECTIVE
			-- rotation (Motor6D.Transform — the exact channel the snapshot reads) AFTER StepAnimations.
			-- Any clobber source (stale tracks, held-rig state, future regressions) fails loudly HERE
			-- instead of silently keying a lie.
			for i, e in poseEntries do
				local m = poseJoints[i]
				local want = RigWorkbench.rotationCFrame(e.x, e.y, e.z)
				local delta = AnimationClip.rotationDeltaDeg(want, m.Transform)
				if delta > VERIFY_TOLERANCE_DEG then
					local gx, gy, gz = m.Transform:ToEulerAnglesXYZ()
					return string.format(
						"add_keyframe: pose verify FAILED — posed %s, requested (%g, %g, %g) deg but it "
							.. "reads back (%.1f, %.1f, %.1f) deg (off by %.1f deg > %d deg) — pose did "
							.. "not take; suspect stale tracks or held-rig C0 state. NO keyframe was "
							.. "written (the batch was rolled back).",
						e.name,
						e.x,
						e.y,
						e.z,
						math.deg(gx),
						math.deg(gy),
						math.deg(gz),
						delta,
						VERIFY_TOLERANCE_DEG
					),
						false
				end
			end
		end
		return AnimationClip.snapshotKeyframe(rig :: Instance, clip, time, scopeNames)
	end)
	if ok and posedApplied then
		text = string.format(
			"%d joint(s) posed + read-back verified within %d deg + keyframe at t=%g.",
			#poseEntries,
			VERIFY_TOLERANCE_DEG,
			AnimationClip.normalizeTime(time)
		) .. "\n" .. text
	end
	if purged > 0 then
		text = string.format("stopped %d stale playing track(s) first.", purged) .. "\n" .. text
	end
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
		description = "Author an animation by SNAPSHOTTING the rig's current pose as a keyframe. PREFER the "
			.. "batch form — author a keypose per call: poses map + time; 3-5 keyposes suffice for the "
			.. "oracle's sweep checks. poses = { [jointName] = {x?,y?,z?} } in DEGREES poses those joints "
			.. "FIRST (ABSOLUTE, i.e. pose_joint relative=false: each call states the complete keypose, and "
			.. "an all-zeros entry returns a joint to neutral — no reset_pose between keyposes), then "
			.. "snapshots. Unknown joint names error BEFORE anything is posed or keyed. Without poses, pose "
			.. "the rig first (pose_joint / ik_reach), then call this to capture that pose at `time` seconds "
			.. "into a clip (a KeyframeSequence saved under rig/AnimSaves/<clip>, the Animation Editor's "
			.. "folder). Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip'), time (seconds; omit to append after the last keyframe), poses "
			.. "(optional batch keypose map), scope "
			.. "(optional — keys only a subset of joints: 'rightArm' for an item swing/use clip so the "
			.. "legs/torso keep their own animation, 'upperBody', or an array of joint child-part names; "
			.. "omit for a full-body clip), weapon (optional boolean — ALSO key the equipped Tool's "
			.. "Handle so the clip moves the WEAPON itself; pose the grip via poses={AgentEditGrip={x=40}} "
			.. "with weapon=true, scope='rightArm'). "
			.. "Re-snapshots replace any keyframe already at that time. Stale playing AnimationTracks "
			.. "are stopped first (noted in the result), and every batch-posed joint is READ BACK after "
			.. "apply — a >2 deg mismatch errors and refuses the keyframe (no silent frozen snapshots). "
			.. "Then use capture_animation to SEE it.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
				time = {
					type = "number",
					description = "Keyframe time in seconds (omit = append).",
				},
				poses = {
					type = "object",
					description = "Batch keypose: { [jointName] = {x?,y?,z?} } in DEGREES (names from "
						.. "get_rig; 'AgentEditGrip' = the weapon grip). Poses those joints FIRST — "
						.. "ABSOLUTE, all-zeros = neutral; joints not in the map keep their current "
						.. "pose — then snapshots. Unknown names error before any mutation.",
				},
				scope = {
					description = "Joint scope: 'rightArm' (key only the right-arm chain — use for "
						.. "item swing/use clips so the legs/torso keep their own animation), 'upperBody', "
						.. "or an array of joint child-part names. Omit to key ALL joints (full-body).",
				},
				weapon = {
					type = "boolean",
					description = "true = ALSO key the equipped Tool's Handle (the AgentEditGrip weapon "
						.. "channel) so the clip animates the weapon itself.",
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
