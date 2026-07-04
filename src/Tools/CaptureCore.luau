--!strict
-- CaptureCore: the shared engine for the capture tools. PURE helpers (camera framing math, presets,
-- elevation) are unit-tested in CaptureSpec; IMPURE helpers (camera save/set/restore,
-- CaptureScreenshot trigger, sidecar HTTP fetch, target resolution) are added in Task 4 and are
-- LIVE-verified in Studio. A plugin can't read the capture file, so the impure fetch asks the local
-- sidecar to read the newest wob PNG(s) off disk. See the multi-capture design spec.

local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CaptureService = game:GetService("CaptureService")
local Selection = game:GetService("Selection")

local Path = require(script.Parent.Path)

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

export type CameraState = { camType: Enum.CameraType, cframe: CFrame, fov: number }?

function CaptureCore.saveCamera(): CameraState
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return nil
	end
	return { camType = cam.CameraType, cframe = cam.CFrame, fov = cam.FieldOfView }
end

function CaptureCore.restoreCamera(state: CameraState)
	local cam = Workspace.CurrentCamera
	if cam == nil or state == nil then
		return
	end
	cam.CameraType = state.camType
	cam.CFrame = state.cframe
	cam.FieldOfView = state.fov
end

function CaptureCore.setCamera(cframe: CFrame)
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cframe
end

-- Let the viewport re-render the new camera/pose before we capture.
function CaptureCore.settle(frames: number?)
	for _ = 1, (frames or 2) do
		RunService.Heartbeat:Wait()
	end
end

-- Trigger one CaptureScreenshot and yield until the engine invokes the callback (or a timeout). We
-- don't need the rbxtemp id — the sidecar reads the file by mtime. Returns true if the callback fired.
-- The Studio Selection is stashed for the shot: its bright adornment otherwise renders INTO the
-- screenshot (the "giant cyan box" that made rigs unjudgeable), then restored even on timeout.
function CaptureCore.triggerCapture(timeoutS: number?): boolean
	local prevSelection = Selection:Get()
	Selection:Set({})
	CaptureCore.settle(1) -- one frame so the adornment is gone before the engine samples the viewport
	local done = false
	local ok = pcall(function()
		CaptureService:CaptureScreenshot(function(_id)
			done = true
		end)
	end)
	if ok then
		local deadline = os.clock() + (timeoutS or 5)
		while not done and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end
	end
	Selection:Set(prevSelection)
	return ok and done
end

-- World-AABB (center, size) over every BasePart under the given roots (oriented part corners), nil if
-- none. Reads parts (impure). Exposed for capture_animation's swept-extent measure pass.
function CaptureCore.aabbOf(roots: { Instance }): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	local function acc(part: BasePart)
		local cf, sz = part.CFrame, part.Size
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				for _, sz2 in { -0.5, 0.5 } do
					local p = (cf * CFrame.new(sz.X * sx, sz.Y * sy, sz.Z * sz2)).Position
					if minV == nil or maxV == nil then
						minV, maxV = p, p
					else
						minV = Vector3.new(
							math.min(minV.X, p.X),
							math.min(minV.Y, p.Y),
							math.min(minV.Z, p.Z)
						)
						maxV = Vector3.new(
							math.max(maxV.X, p.X),
							math.max(maxV.Y, p.Y),
							math.max(maxV.Z, p.Z)
						)
					end
				end
			end
		end
	end
	for _, root in roots do
		if root:IsA("BasePart") then
			acc(root)
		end
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				acc(d)
			end
		end
	end
	if minV == nil or maxV == nil then
		return nil, nil
	end
	return (minV + maxV) / 2, (maxV - minV)
end

-- Pure: union a list of axis-aligned boxes given as { center, size }. Returns (center, size) of the
-- union, or (nil, nil) for an empty list. Used to frame the SWEPT extent of an animation across its
-- sampled poses (capture_animation) so action poses that exceed the resting box still fit. Mirrors
-- aabbOf's min/max accumulation but over precomputed boxes (no DataModel reads -> unit-testable).
function CaptureCore.unionAABB(boxes: { { center: Vector3, size: Vector3 } }): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, b in boxes do
		local half = b.size / 2
		local lo = b.center - half
		local hi = b.center + half
		if minV == nil or maxV == nil then
			minV, maxV = lo, hi
		else
			minV =
				Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
			maxV =
				Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		end
	end
	if minV == nil or maxV == nil then
		return nil, nil
	end
	return (minV + maxV) / 2, (maxV - minV)
end

-- Resolve the target into (center, size, errString). A path string, or (nil/empty) the current
-- Studio Selection. Unions the bounding boxes of all resolved instances' BaseParts.
function CaptureCore.resolveTarget(target: any): (Vector3?, Vector3?, string?)
	local roots: { Instance } = {}
	if type(target) == "string" and target ~= "" then
		-- Shared resolver: accepts "game.Workspace.X", "Workspace.X", "workspace.X", service names.
		local inst, perr = Path.resolve(target)
		if inst == nil then
			return nil, nil, "target not found: " .. target .. " (" .. tostring(perr) .. ")"
		end
		table.insert(roots, inst)
	else
		for _, inst in Selection:Get() do
			table.insert(roots, inst)
		end
		if #roots == 0 then
			return nil,
				nil,
				"nothing selected — select a part/model in Studio or pass a target path."
		end
	end
	local center, size = CaptureCore.aabbOf(roots)
	if center == nil or size == nil then
		return nil, nil, "target has no parts to frame (no BasePart found)."
	end
	return center, size, nil
end

-- Ask the sidecar for `count` newest capture PNGs created at/after `since` (epoch seconds). Returns
-- (blocks, nil) on success — a list of base64 image blocks — or (nil, errString) on any failure.
function CaptureCore.fetchCaptures(count: number, since: number, config: any): ({ any }?, string?)
	if config == nil then
		return nil, "capture: internal error (no config available)"
	end
	local url = config:getSidecarUrl()
		.. "/captures?b64=1&count="
		.. tostring(count)
		.. "&since="
		.. tostring(math.floor(since))

	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
		})
	end)
	if not ok then
		local msg = string.lower(tostring(res))
		if string.find(msg, "not enabled", 1, true) then
			return nil,
				"capture: HTTP requests are disabled. Enable 'Allow HTTP Requests' in Game "
					.. "Settings > Security."
		end
		if string.find(msg, "game server", 1, true) then
			return nil,
				"capture: HttpService is server-only — capture from edit mode or the Studio Server view."
		end
		return nil,
			"capture: could not reach the vision sidecar at "
				.. config:getSidecarUrl()
				.. " — is it running? Start StudioAgentSidecar.exe (sidecar/dist). ("
				.. tostring(res)
				.. ")"
	end

	local response = res :: any
	if not response.Success then
		return nil,
			"capture: the sidecar returned HTTP "
				.. tostring(response.StatusCode)
				.. ": "
				.. tostring(response.Body)
	end

	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okDecode or type(payload) ~= "table" or type((payload :: any).images) ~= "table" then
		return nil, "capture: the sidecar returned an unexpected response."
	end
	local blocks: { any } = {}
	for _, b64 in (payload :: any).images do
		local data = (string.gsub(tostring(b64), "%s", ""))
		if data ~= "" then
			table.insert(blocks, {
				type = "image",
				source = { type = "base64", media_type = "image/png", data = data },
			})
		end
	end
	if #blocks == 0 then
		return nil, "capture: the sidecar returned no images (try focusing Studio once and retry)."
	end
	return blocks, nil
end

return CaptureCore
