--!strict
-- CameraRig: a stateful, navigable "spherical camera-lock rig". Locks the editor camera aiming at a
-- target and orbits it on a sphere (azimuth + elevation + radius), driven by relative moves. Reuses
-- CaptureCore for all framing/camera math (frameCFrame/setCamera/saveCamera/restoreCamera/resolveTarget),
-- so it never hand-writes CFrames. PURE helpers (wrapAzimuth/clampElevation/clampZoom/applyMove) are
-- unit-tested in CameraRigSpec; the methods touch CaptureCore + Workspace. One instance in deps.cameraRig.
-- Optional DEBUG gizmos (Config cameraRigDebug, default off) visualize the orbit sphere/camera/pivot.

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local CaptureCore = require(script.Parent.Tools.CaptureCore)

local CameraRig = {}
CameraRig.__index = CameraRig

local ELEV_MIN, ELEV_MAX = -89, 89
local ZOOM_MIN, ZOOM_MAX = 0.2, 8
local GIZMO_FOLDER = "__StudioAgentCameraRig"
local GIZMO_TAG = "StudioAgentCameraRigGizmo"

export type State = { azimuth: number, elevation: number, distScale: number }
export type Move = { azimuth: number?, elevation: number?, zoom: number?, relative: boolean? }

-- ---- pure helpers (no DataModel — directly unit-testable) ----

function CameraRig.wrapAzimuth(a: number): number
	if a ~= a then
		return 0
	end
	local r = a % 360
	if r < 0 then
		r += 360
	end
	return r
end

function CameraRig.clampElevation(e: number): number
	if e ~= e then
		return 0
	end
	if e < ELEV_MIN then
		return ELEV_MIN
	end
	if e > ELEV_MAX then
		return ELEV_MAX
	end
	return e
end

function CameraRig.clampZoom(z: number): number
	if z ~= z then
		return 1
	end
	if z < ZOOM_MIN then
		return ZOOM_MIN
	end
	if z > ZOOM_MAX then
		return ZOOM_MAX
	end
	return z
end

-- Apply a move to a state. relative (default true) adds deltas; false sets absolute values. Missing
-- fields keep the current value. Returns a NEW clamped/wrapped state.
function CameraRig.applyMove(state: State, move: Move): State
	local relative = move.relative ~= false
	local az, el, z = state.azimuth, state.elevation, state.distScale
	if move.azimuth ~= nil then
		az = if relative then az + move.azimuth else move.azimuth
	end
	if move.elevation ~= nil then
		el = if relative then el + move.elevation else move.elevation
	end
	if move.zoom ~= nil then
		z = if relative then z + move.zoom else move.zoom
	end
	return {
		azimuth = CameraRig.wrapAzimuth(az),
		elevation = CameraRig.clampElevation(el),
		distScale = CameraRig.clampZoom(z),
	}
end

-- ---- instance (live controller) ----

export type CameraRig = typeof(setmetatable(
	{} :: {
		_config: any,
		_center: Vector3?,
		_size: Vector3?,
		_state: State,
		_saved: any,
	},
	CameraRig
))

local function defaultState(): State
	return { azimuth = 35, elevation = 20, distScale = 1 }
end

function CameraRig.new(config: any): CameraRig
	return setmetatable({
		_config = config,
		_center = nil,
		_size = nil,
		_state = defaultState(),
		_saved = nil,
	}, CameraRig)
end

function CameraRig.isDebug(self: CameraRig): boolean
	return self._config ~= nil and self._config:getCameraRigDebug() == true
end

local function removeFolder()
	local existing = Workspace:FindFirstChild(GIZMO_FOLDER)
	if existing ~= nil then
		existing:Destroy()
	end
end

function CameraRig.removeGizmos(_self: CameraRig)
	removeFolder()
end

local function gizmoBall(color: Color3, diameter: number, pos: Vector3, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Locked = true
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Transparency = transparency
	p.Size = Vector3.new(diameter, diameter, diameter)
	p.CFrame = CFrame.new(pos)
	return p
end

-- Draw/refresh the debug gizmos: orbit sphere + pivot marker + camera marker. No-op if not focused.
function CameraRig.drawGizmos(self: CameraRig)
	removeFolder()
	if self._center == nil then
		return
	end
	local center = self._center :: Vector3
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return
	end
	local camPos = cam.CFrame.Position
	local radius = math.max((camPos - center).Magnitude, 1)
	local folder = Instance.new("Folder")
	folder.Name = GIZMO_FOLDER
	CollectionService:AddTag(folder, GIZMO_TAG)

	local sphere = gizmoBall(Color3.fromRGB(80, 160, 255), radius * 2, center, 0.85)
	sphere.Name = "OrbitSphere"
	sphere.Parent = folder

	local pivot = gizmoBall(Color3.fromRGB(255, 200, 0), 1, center, 0)
	pivot.Name = "Pivot"
	pivot.Parent = folder

	local camMarker = gizmoBall(Color3.fromRGB(255, 60, 60), 1.5, camPos, 0)
	camMarker.Name = "CameraMarker"
	camMarker.Parent = folder

	folder.Parent = Workspace
end

function CameraRig.setDebug(self: CameraRig, on: boolean)
	if self._config ~= nil then
		self._config:set("cameraRigDebug", on == true)
	end
	if on then
		self:drawGizmos()
	else
		self:removeGizmos()
	end
end

-- Lock onto a target (path or selection). Frames it at a 3/4 view, saves the user's camera (first
-- focus), sets the camera, refreshes gizmos if debug. Returns (state, errString?).
function CameraRig.focus(self: CameraRig, target: any): (State?, string?)
	local center, size, err = CaptureCore.resolveTarget(target)
	if center == nil or size == nil then
		return nil, err
	end
	if self._saved == nil then
		self._saved = CaptureCore.saveCamera()
	end
	self._center = center
	self._size = size
	self._state = defaultState()
	CaptureCore.setCamera(
		CaptureCore.frameCFrame(
			center :: Vector3,
			size :: Vector3,
			self._state.azimuth,
			self._state.elevation,
			self._state.distScale
		)
	)
	if self:isDebug() then
		self:drawGizmos()
	end
	return self._state, nil
end

-- Apply a relative/absolute orbit move. Requires a prior focus. Returns (state, errString?).
function CameraRig.orbit(self: CameraRig, move: Move): (State?, string?)
	if self._center == nil or self._size == nil then
		return nil, "no target locked — call camera_focus first."
	end
	self._state = CameraRig.applyMove(self._state, move)
	CaptureCore.setCamera(
		CaptureCore.frameCFrame(
			self._center :: Vector3,
			self._size :: Vector3,
			self._state.azimuth,
			self._state.elevation,
			self._state.distScale
		)
	)
	if self:isDebug() then
		self:drawGizmos()
	end
	return self._state, nil
end

-- Restore the user's pre-focus camera + clear gizmos + unlock. Returns whether a target was locked.
function CameraRig.release(self: CameraRig): boolean
	self:removeGizmos()
	if self._saved ~= nil then
		CaptureCore.restoreCamera(self._saved)
		self._saved = nil
	end
	local was = self._center ~= nil
	self._center = nil
	self._size = nil
	return was
end

function CameraRig.state(self: CameraRig): State
	return self._state
end

return CameraRig
