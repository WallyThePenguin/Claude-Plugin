--!strict
-- CaptureCore: the shared engine for the capture tools. PURE helpers (camera framing math, presets,
-- downscale policy, elevation) are unit-tested in CaptureSpec; IMPURE helpers (camera save/set/restore,
-- CaptureScreenshot trigger, sidecar HTTP fetch, target resolution) are added in Task 4 and are
-- LIVE-verified in Studio. A plugin can't read the capture file, so the impure fetch asks the local
-- sidecar to read the newest wob PNG(s) off disk. See the multi-capture design spec.

local CaptureCore = {}

local DEFAULT_FOV = 70 -- degrees; Studio's default camera FieldOfView
local FIT_MARGIN = 1.2 -- pad the bounding sphere so the target isn't edge-to-edge

-- preset name -> (yawDeg, pitchDeg). top/bottom use 89/-89 to avoid the CFrame.lookAt up-vector
-- degeneracy at a perfectly vertical view.
CaptureCore.PRESETS = {
	front = { yaw = 0, pitch = 0 },
	back = { yaw = 180, pitch = 0 },
	right = { yaw = 90, pitch = 0 },
	left = { yaw = -90, pitch = 0 },
	top = { yaw = 0, pitch = 89 },
	bottom = { yaw = 0, pitch = -89 },
	iso = { yaw = 45, pitch = 30 },
} :: { [string]: { yaw: number, pitch: number } }

-- N evenly-spaced yaw angles (degrees) starting at 0.
function CaptureCore.yawsFor(count: number): { number }
	local yaws: { number } = {}
	for i = 0, count - 1 do
		table.insert(yaws, (360 / count) * i)
	end
	return yaws
end

-- Camera CFrame framing the target's bounding sphere from (yaw, pitch) at a fitted distance.
-- Pure + deterministic. yaw rotates around Y (0 = eye on +Z looking toward -Z at the center).
function CaptureCore.frameCFrame(
	center: Vector3,
	size: Vector3,
	yawDeg: number,
	pitchDeg: number,
	distScale: number,
	fovDeg: number?
): CFrame
	local fov = fovDeg or DEFAULT_FOV
	local radius = math.max(size.Magnitude / 2, 1)
	local distance = (radius / math.tan(math.rad(fov) / 2)) * FIT_MARGIN * distScale
	local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
	local dir = Vector3.new(
		math.cos(pitch) * math.sin(yaw),
		math.sin(pitch),
		math.cos(pitch) * math.cos(yaw)
	)
	return CFrame.lookAt(center + dir * distance, center)
end

-- Downscale ceiling so a batch stays under Anthropic's per-request limits: >20 images must each be
-- <=2000px (the "many-image" rule), and the 32MB request payload caps total bytes. nil = native res.
function CaptureCore.maxPxForCount(count: number): number?
	if count <= 20 then
		return nil
	elseif count <= 50 then
		return 2000
	elseif count <= 100 then
		return 1280
	end
	return 768
end

-- "low"/"eye"/"high" or a numeric degrees -> pitch degrees.
function CaptureCore.elevationPitch(elevation: any): number
	if type(elevation) == "number" then
		return elevation
	elseif elevation == "low" then
		return 5
	elseif elevation == "high" then
		return 45
	end
	return 20 -- "eye" / default
end

return CaptureCore
