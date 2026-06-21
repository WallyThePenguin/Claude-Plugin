--!strict
-- Capture: the vision tools. A plugin can't read viewport pixels, so each tool triggers
-- CaptureService:CaptureScreenshot (which writes a full-res viewport PNG to disk) and asks the local
-- sidecar to read the newest file(s). Three tools share CaptureCore:
--   capture           - one shot at the current camera.
--   capture_angles    - orbit a target: N framed angles (objects/assets/art).
--   capture_animation - filmstrip: time-sampled frames of a clip/animation via TimePosition scrub + StepAnimations (edit-mode).
-- These return STRUCTURED content (a tool_result blocks array of text labels + base64 images);
-- AgentLoop forwards the array verbatim. On ANY failure they fall back to a STRING error (isError=true).

local CaptureCore = require(script.Parent.CaptureCore)
local Selection = game:GetService("Selection")
local AnimationClip = require(script.Parent.Parent.AnimationClip)
local RigWorkbench = require(script.Parent.Parent.RigWorkbench)
local Path = require(script.Parent.Path)

local Capture = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local function getConfig(context: any): any
	return if type(context) == "table" then context.config else nil
end

-- ---- capture (single) -------------------------------------------------------

local function runSingle(_input: any, context: any): (any, boolean)
	local since = os.time() - 2
	if not CaptureCore.triggerCapture() then
		return "capture: CaptureService did not produce a screenshot (ensure Studio is focused, retry).",
			true
	end
	CaptureCore.settle(1)
	local blocks, err = CaptureCore.fetchCaptures(1, since, getConfig(context))
	if blocks == nil then
		return err :: string, true
	end
	return blocks, false
end

-- ---- capture_angles (orbit) -------------------------------------------------

type Shot = { yaw: number, pitch: number, label: string }

local function runAngles(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	local center, size, terr = CaptureCore.resolveTarget(args.target)
	if center == nil or size == nil then
		return "capture_angles: " .. tostring(terr), true
	end

	local shots: { Shot } = {}
	if type(args.presets) == "table" and #args.presets > 0 then
		for _, name in args.presets do
			local p = CaptureCore.PRESETS[string.lower(tostring(name))]
			if p ~= nil then
				table.insert(shots, { yaw = p.yaw, pitch = p.pitch, label = tostring(name) })
			end
		end
		if #shots == 0 then
			return "capture_angles: no valid presets (use front/back/left/right/top/bottom/iso).",
				true
		end
	else
		local count = if type(args.count) == "number" and args.count >= 1
			then math.floor(args.count)
			else 6
		count = math.min(count, 20) -- batch cap: keeps requests within Anthropic's image limits
		local pitch = CaptureCore.elevationPitch(args.elevation)
		for _, yaw in CaptureCore.yawsFor(count) do
			table.insert(shots, {
				yaw = yaw,
				pitch = pitch,
				label = string.format("%d deg", math.floor(yaw + 0.5)),
			})
		end
	end

	local distScale = if type(args.distance) == "number" and args.distance > 0
		then args.distance
		else 1
	local saved = CaptureCore.saveCamera()
	local since = os.time() - 2
	local triggered = 0
	local okAll = pcall(function()
		for _, shot in shots do
			CaptureCore.setCamera(
				CaptureCore.frameCFrame(
					center :: Vector3,
					size :: Vector3,
					shot.yaw,
					shot.pitch,
					distScale
				)
			)
			CaptureCore.settle(2)
			if CaptureCore.triggerCapture() then
				triggered += 1
			end
		end
	end)
	CaptureCore.restoreCamera(saved)

	if not okAll or triggered == 0 then
		return "capture_angles: failed to capture any angle (camera restored).", true
	end
	local blocks, err = CaptureCore.fetchCaptures(triggered, since, getConfig(context))
	if blocks == nil then
		return err :: string, true
	end

	local content: { any } = {
		{ type = "text", text = string.format("%d viewport angles of the target:", #blocks) },
	}
	for i, b in blocks do
		local label = if shots[i] ~= nil then shots[i].label else tostring(i)
		table.insert(content, {
			type = "text",
			text = string.format("angle %d/%d — %s", i, #blocks, label),
		})
		table.insert(content, b)
	end
	if #blocks < #shots then
		table.insert(content, {
			type = "text",
			text = string.format(
				"(note: %d of %d frames returned; if you need more, reduce the count or retry)",
				#blocks,
				#shots
			),
		})
	end
	return content, false
end

-- ---- capture_animation (filmstrip) -----------------------------------------
-- Edit-mode scrub-and-sample: register the clip/animation, Play it on a temp track, set TimePosition +
-- StepAnimations(0) per sample time (Roblox's own interpolation), capture, then restore the working pose
-- and tear the playback down. Proven live (LIVE-TEST #2).

-- get-or-create the rig's Animator (block rigs have a Humanoid). nil if the rig has no controller.
local function rigAnimator(rig: Instance): Animator?
	local controller = rig:FindFirstChildOfClass("Humanoid")
		or rig:FindFirstChildOfClass("AnimationController")
	if controller == nil then
		return nil
	end
	local existing = controller:FindFirstChildOfClass("Animator")
	if existing ~= nil then
		return existing
	end
	local a = Instance.new("Animator")
	a.Parent = controller
	return a
end

local function saveTransforms(rig: Instance): { [Motor6D]: CFrame }
	local map: { [Motor6D]: CFrame } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			map[d :: Motor6D] = (d :: Motor6D).Transform
		end
	end
	return map
end

local function restoreTransforms(map: { [Motor6D]: CFrame })
	for m, cf in map do
		m.Transform = cf
	end
end

-- Resolve (rig, animationId, err). Source = a working `clip` (AnimSaves under the rig) or `animation`
-- (an asset id, or a path to a KeyframeSequence instance). rig = path arg or the current selection.
local function resolveSource(args: any): (Instance?, string?, string?)
	local rig: Instance? = nil
	local rigErr: string? = nil
	if type(args.rig) == "string" and args.rig ~= "" then
		rig, rigErr = Path.resolve(args.rig)
	else
		local sel = Selection:Get()
		rig = if #sel > 0 then sel[1] else nil
	end
	if rig == nil then
		return nil,
			nil,
			"capture_animation: "
				.. (rigErr or "no rig given and nothing selected — pass a rig path or select it.")
	end
	if not rig:IsA("Model") then
		return nil, nil, "capture_animation: the rig must be a Model (with a bounding box)."
	end
	if type(args.clip) == "string" and args.clip ~= "" then
		local ks = AnimationClip.findClip(rig, args.clip)
		if ks == nil then
			return nil,
				nil,
				"capture_animation: no clip '"
					.. args.clip
					.. "' under "
					.. rig.Name
					.. "/AnimSaves."
		end
		local id, ierr = AnimationClip.register(ks)
		if id == nil then
			return nil, nil, "capture_animation: " .. tostring(ierr)
		end
		return rig, id, nil
	end
	if type(args.animation) == "string" and args.animation ~= "" then
		local maybe = Path.resolve(args.animation)
		if maybe ~= nil and maybe:IsA("KeyframeSequence") then
			local id, ierr = AnimationClip.register(maybe :: KeyframeSequence)
			if id == nil then
				return nil, nil, "capture_animation: " .. tostring(ierr)
			end
			return rig, id, nil
		end
		local raw = args.animation :: string
		local id = if string.match(raw, "^%d+$") ~= nil then "rbxassetid://" .. raw else raw
		return rig, id, nil
	end
	return nil,
		nil,
		"capture_animation: pass a working `clip` name or an `animation` (asset id / KeyframeSequence path)."
end

local function runAnimation(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, animId, serr = resolveSource(args)
	if rig == nil or animId == nil then
		return serr :: string, true
	end
	local animator = rigAnimator(rig)
	if animator == nil then
		return "capture_animation: the rig has no Humanoid or AnimationController, so it can't play an "
			.. "animation. Use a native rig (spawn_rig) or add an AnimationController.",
			true
	end

	-- Snapshot the working pose + camera BEFORE loading/playing anything, so we can fully restore them
	-- afterward (playback + StepAnimations would otherwise overwrite the joints' Transforms).
	local savedTransforms = saveTransforms(rig)
	local savedCam = CaptureCore.saveCamera()

	-- A parentless Animation is fine for LoadAnimation (verified live).
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local okLoad, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not okLoad or track == nil then
		anim:Destroy()
		return "capture_animation: couldn't load the animation (" .. tostring(track) .. ").", true
	end
	local animTrack = track :: AnimationTrack
	animTrack.Priority = Enum.AnimationPriority.Action
	animTrack:Play(0)

	-- poll for the clip data to resolve (Length stays 0 until loaded)
	local deadline = os.clock() + 4
	while animTrack.Length <= 0 and os.clock() < deadline do
		CaptureCore.settle(1)
	end
	local length = animTrack.Length
	if length <= 0 then
		animTrack:Stop()
		animTrack:Destroy()
		anim:Destroy()
		return "capture_animation: the clip has no length (empty? add keyframes first).", true
	end

	local frames = if type(args.frames) == "number"
		then math.clamp(math.floor(args.frames), 2, 20)
		else 8
	local startT = if type(args.startTime) == "number" then math.max(0, args.startTime) else 0
	local endT = if type(args.endTime) == "number" then math.min(args.endTime, length) else length
	if endT <= startT then
		startT, endT = 0, length
	end

	local preset = CaptureCore.PRESETS[string.lower(tostring(args.angle))]
		or CaptureCore.PRESETS.front
	local boundCF, boundSize = (rig :: Model):GetBoundingBox()
	CaptureCore.setCamera(
		CaptureCore.frameCFrame(boundCF.Position, boundSize, preset.yaw, preset.pitch, 1)
	)

	local since = os.time() - 2
	local triggered = 0
	local labels: { string } = {}
	local okAll = pcall(function()
		for i = 0, frames - 1 do
			local t = startT + (endT - startT) * (i / (frames - 1))
			animTrack.TimePosition = t
			animator:StepAnimations(0)
			CaptureCore.settle(2)
			if CaptureCore.triggerCapture() then
				triggered += 1
				table.insert(labels, string.format("%.2fs", t))
			end
		end
	end)

	-- restore everything (always): stop + destroy the temp track/Animation, restore the working pose,
	-- re-show it (StepAnimations with no playing track), restore the camera.
	animTrack:Stop()
	animTrack:Destroy()
	anim:Destroy()
	restoreTransforms(savedTransforms)
	RigWorkbench.applyPose(rig)
	CaptureCore.restoreCamera(savedCam)

	if not okAll or triggered == 0 then
		return "capture_animation: failed to sample the animation (state restored).", true
	end
	local blocks, err = CaptureCore.fetchCaptures(triggered, since, getConfig(context))
	if blocks == nil then
		return err :: string, true
	end
	local content: { any } = {
		{
			type = "text",
			text = string.format("%d-frame filmstrip (%.2fs to %.2fs):", #blocks, startT, endT),
		},
	}
	for i, b in blocks do
		local label = if labels[i] ~= nil then labels[i] else tostring(i)
		table.insert(
			content,
			{ type = "text", text = string.format("frame %d/%d — t=%s", i, #blocks, label) }
		)
		table.insert(content, b)
	end
	return content, false
end

-- ---- descriptors ------------------------------------------------------------

Capture.descriptors = {
	{
		name = "capture",
		description = "Take a SCREENSHOT of the current Studio VIEWPORT and SEE it (returned as an "
			.. "image). Use it to visually verify anything with an appearance — GUIs, scenes, rigs, a "
			.. "single framing — then adjust and capture again. Requires the local vision sidecar; if "
			.. "it isn't running, returns an error explaining how to start it.",
		inputSchema = { type = "object", properties = {} },
		destructive = false,
		run = runSingle,
	},
	{
		name = "capture_angles",
		description = "Capture a target from MULTIPLE camera angles in one call — give a target and a "
			.. "count and the tool frames it and orbits automatically (you NEVER compute camera "
			.. "CFrames). Use it to inspect/build an object, asset, or art from several sides. Inputs: "
			.. "target (instance path; defaults to the current Studio selection), count (default 6), "
			.. "elevation (low/eye/high or degrees), distance (zoom scale), or presets (e.g. "
			.. "['front','left','top']) to override the even orbit. Returns the angles as labeled images.",
		inputSchema = {
			type = "object",
			properties = {
				target = {
					type = "string",
					description = "Instance path; omit to use the selection.",
				},
				count = {
					type = "number",
					description = "Number of evenly-spaced angles (default 6).",
				},
				elevation = {
					type = "string",
					description = "low | eye | high, or a pitch in degrees as a number.",
				},
				distance = {
					type = "number",
					description = "Zoom scale of the auto-fit (default 1.0).",
				},
				presets = {
					type = "array",
					items = { type = "string" },
					description = "Named angles (front/back/left/right/top/bottom/iso); overrides the orbit.",
				},
			},
		},
		destructive = false,
		run = runAngles,
	},
	{
		name = "capture_animation",
		description = "See an animation as a time-sampled FILMSTRIP from a fixed angle, so you can review a "
			.. "motion end-to-end in edit. Source: a working `clip` (a clip you authored with add_keyframe, "
			.. "under rig/AnimSaves) OR an existing `animation` (an asset id or a KeyframeSequence path). It "
			.. "registers + plays the clip and samples frames across time (no upload). Inputs: rig (path or "
			.. "selection), clip OR animation, frames (default 8), startTime/endTime (seconds; default full "
			.. "clip), angle (front/back/left/right/top/bottom/iso). LOOK at the frames and iterate. Restores "
			.. "your working pose when done.",
		inputSchema = {
			type = "object",
			properties = {
				rig = {
					type = "string",
					description = "Path to the rig (Model with an Animator/Humanoid); omit to use the selection.",
				},
				clip = {
					type = "string",
					description = "A working clip name under rig/AnimSaves (e.g. 'AgentClip').",
				},
				animation = {
					type = "string",
					description = "An existing animation: asset id or a KeyframeSequence path.",
				},
				frames = {
					type = "number",
					description = "Number of time samples (default 8, max 20).",
				},
				startTime = { type = "number", description = "Start time in seconds (default 0)." },
				endTime = {
					type = "number",
					description = "End time in seconds (default clip length).",
				},
				angle = {
					type = "string",
					description = "A preset angle (front/back/left/right/top/bottom/iso).",
				},
			},
		},
		destructive = false,
		run = runAnimation,
	},
} :: { Descriptor }

return Capture
