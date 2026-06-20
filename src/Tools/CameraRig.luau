--!strict
-- Camera-rig tools: camera_focus / camera_orbit / camera_release. Drive the stateful spherical
-- CameraRig (context.cameraRig) and capture after each move so the agent SEES the result. Parent-only
-- (not in subagent allowlists; nil-guards context.cameraRig). Non-destructive (a camera move isn't a
-- place-content edit). focus/orbit return a tool_result blocks array (a state line + the image), like
-- capture_angles; on any failure they fall back to a string error (isError=true).

local CaptureCore = require(script.Parent.CaptureCore)

local CameraRigTools = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local function rig(context: any): any
	return if type(context) == "table" then context.cameraRig else nil
end

local function stateLine(prefix: string, s: any): string
	return string.format(
		"%s — azimuth %d°, elevation %d°, zoom %.2f",
		prefix,
		math.floor(s.azimuth + 0.5),
		math.floor(s.elevation + 0.5),
		s.distScale
	)
end

-- After a camera move, capture the viewport and return [state text + image]. (content, isError).
local function captureWithState(text: string, context: any): (any, boolean)
	local since = os.time() - 2
	if not CaptureCore.triggerCapture() then
		return "camera: CaptureService did not produce a screenshot (focus Studio and retry).", true
	end
	CaptureCore.settle(2)
	local config = if type(context) == "table" then context.config else nil
	local blocks, err = CaptureCore.fetchCaptures(1, since, config)
	if blocks == nil then
		return err :: string, true
	end
	local content: { any } = { { type = "text", text = text } }
	for _, b in blocks do
		table.insert(content, b)
	end
	return content, false
end

local function maybeSetDebug(r: any, args: any)
	if type(args.debug) == "boolean" then
		r:setDebug(args.debug)
	end
end

local function runFocus(input: any, context: any): (any, boolean)
	local r = rig(context)
	if r == nil then
		return "camera_focus is not available here (no camera rig in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	maybeSetDebug(r, args)
	local state, err = r:focus(args.target)
	if state == nil then
		return "camera_focus: " .. tostring(err), true
	end
	return captureWithState(stateLine("locked + framed", state), context)
end

local function runOrbit(input: any, context: any): (any, boolean)
	local r = rig(context)
	if r == nil then
		return "camera_orbit is not available here (no camera rig in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	maybeSetDebug(r, args)
	local move = {
		azimuth = if type(args.azimuth) == "number" then args.azimuth else nil,
		elevation = if type(args.elevation) == "number" then args.elevation else nil,
		zoom = if type(args.zoom) == "number" then args.zoom else nil,
		relative = args.relative ~= false,
	}
	local state, err = r:orbit(move)
	if state == nil then
		return "camera_orbit: " .. tostring(err), true
	end
	return captureWithState(stateLine("moved", state), context)
end

local function runRelease(_input: any, context: any): (any, boolean)
	local r = rig(context)
	if r == nil then
		return "camera_release is not available here (no camera rig in this context)", true
	end
	local was = r:release()
	return (if was
		then "camera released — your view is restored."
		else "camera was not locked; nothing to release."),
		false
end

CameraRigTools.descriptors = {
	{
		name = "camera_focus",
		description = "LOCK the camera onto a target and frame it (a 3/4 view), then capture so you SEE "
			.. "it. The camera stays locked aiming at the target center; use camera_orbit to move around "
			.. "it and camera_release when done. Inputs: target (instance path; omit to use the current "
			.. "selection), debug (optional bool — show/hide the orbit-sphere gizmos). Returns the framed "
			.. "image + the camera state. Requires the vision sidecar (like capture).",
		inputSchema = {
			type = "object",
			properties = {
				target = {
					type = "string",
					description = "Instance path; omit to use the selection.",
				},
				debug = {
					type = "boolean",
					description = "Show/hide the debug gizmos (orbit sphere/pivot/camera).",
				},
			},
		},
		destructive = false,
		run = runFocus,
	},
	{
		name = "camera_orbit",
		description = "Move the locked camera on its sphere and capture. Relative by default — azimuth "
			.. "(horizontal orbit, deg), elevation (vertical orbit, deg; ~89 = birds-eye), zoom (radius "
			.. "delta; negative = closer). Pass relative=false to SET absolute values instead (e.g. "
			.. "elevation=89 for top-down). Requires a prior camera_focus. Returns the new image + state. "
			.. "(You NEVER compute CFrames — describe the move and the rig does the math.)",
		inputSchema = {
			type = "object",
			properties = {
				azimuth = { type = "number", description = "Horizontal orbit in degrees." },
				elevation = {
					type = "number",
					description = "Vertical orbit in degrees (~89 = top).",
				},
				zoom = {
					type = "number",
					description = "Radius change (relative) or absolute zoom scale if relative=false.",
				},
				relative = {
					type = "boolean",
					description = "Default true (deltas). false = set absolute azimuth/elevation/zoom.",
				},
				debug = {
					type = "boolean",
					description = "Show/hide the debug gizmos.",
				},
			},
		},
		destructive = false,
		run = runOrbit,
	},
	{
		name = "camera_release",
		description = "Restore the user's original camera (undo the lock) and remove any debug gizmos. "
			.. "Call this when you're done inspecting so the user gets their view back.",
		inputSchema = { type = "object", properties = {} },
		destructive = false,
		run = runRelease,
	},
} :: { Descriptor }

return CameraRigTools
