--!strict
-- Capture: the vision tools. A plugin can't read viewport pixels, so each tool triggers
-- CaptureService:CaptureScreenshot (which writes a full-res viewport PNG to disk) and asks the local
-- sidecar to read the newest file(s). Three tools share CaptureCore:
--   capture           - one shot at the current camera.
--   capture_angles    - orbit a target: N framed angles (objects/assets/art).
--   capture_animation - filmstrip: time-sampled frames of an animation (review a motion).
-- These return STRUCTURED content (a tool_result blocks array of text labels + base64 images);
-- AgentLoop forwards the array verbatim. On ANY failure they fall back to a STRING error (isError=true).

local CaptureCore = require(script.Parent.CaptureCore)

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
-- Implemented in Task 7 after the edit-mode-playback feasibility spike. Until then it returns a
-- clear, non-crashing error so the registry/relay wiring is testable now.

local function runAnimation(_input: any, _context: any): (any, boolean)
	-- Spike verdict (2026-06-18): in EDIT mode an AnimationTrack's TimePosition does NOT advance (the
	-- animation evaluator only steps during simulation), so sampled frames would be identical.
	-- Filmstrips therefore require a running playtest — a planned follow-up. In edit, author the
	-- animation pose-by-pose and use `capture` between poses to review the motion.
	return "capture_animation: animation filmstrips aren't available in edit yet — an animation's "
		.. "TimePosition doesn't advance without a running playtest, so the frames would be "
		.. "identical. (Playtest-mode filmstrips are a planned follow-up.) To review motion now, "
		.. "capture pose-by-pose in edit, or run a playtest.",
		true
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
		description = "(Requires a running playtest — NOT available in edit mode yet.) Capture a "
			.. "FILMSTRIP of an animation — time-sampled frames of a rig's motion "
			.. "from a fixed angle, so you can review whether an animation looks right end-to-end. "
			.. "Inputs: rig (instance path), animation (asset id or KeyframeSequence path), frames "
			.. "(default 8), startTime/endTime (seconds; defaults to the full clip), angle (a preset). "
			.. "Returns the sampled frames as labeled images.",
		inputSchema = {
			type = "object",
			properties = {
				rig = {
					type = "string",
					description = "Path to the model with an Animator/Humanoid.",
				},
				animation = {
					type = "string",
					description = "Animation asset id or KeyframeSequence path.",
				},
				frames = { type = "number", description = "Number of time samples (default 8)." },
				startTime = { type = "number", description = "Start time in seconds (default 0)." },
				endTime = {
					type = "number",
					description = "End time in seconds (default clip length).",
				},
				angle = { type = "string", description = "A preset angle (front/left/iso/…)." },
			},
			required = { "rig", "animation" },
		},
		destructive = false,
		run = runAnimation,
	},
} :: { Descriptor }

return Capture
