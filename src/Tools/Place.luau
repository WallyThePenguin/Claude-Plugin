--!strict
-- Place: the place_relative tool — position an existing instance relative to an anchor instance by an
-- anchor-LOCAL direction + distance, so the agent never hand-computes facing/CFrame math. PURE math
-- (offsetPoint/DIRS) is unit-tested in PlaceSpec; the impure apply (resolve, region guard, undoable
-- recording) mirrors Create.luau/Properties.luau and is live-verified.
--
-- Tools/ submodule: reaches top-level Serialize via script.Parent.Parent and its Tools siblings
-- (Path, RegionGuard) via script.Parent.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Serialize = require(script.Parent.Parent.Serialize)
local Path = require(script.Parent.Path)
local RegionGuard = require(script.Parent.RegionGuard)

local Place = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"result not JSON-encodable"}'
end

-- Anchor-local unit directions. front = the anchor's facing (local -Z), matching Roblox LookVector.
Place.DIRS = {
	front = Vector3.new(0, 0, -1),
	back = Vector3.new(0, 0, 1),
	right = Vector3.new(1, 0, 0),
	left = Vector3.new(-1, 0, 0),
	up = Vector3.new(0, 1, 0),
	down = Vector3.new(0, -1, 0),
} :: { [string]: Vector3 }

-- World point `distance` studs from anchorCF's center along the anchor-local `direction`. nil if the
-- direction name is unknown. Pure + deterministic.
function Place.offsetPoint(anchorCF: CFrame, direction: string, distance: number): Vector3?
	local unit = Place.DIRS[direction]
	if unit == nil then
		return nil
	end
	return (anchorCF * CFrame.new(unit * distance)).Position
end

-- The anchor's reference CFrame: a BasePart's CFrame, or a Model's pivot. nil if non-spatial.
local function anchorCFrame(inst: Instance): CFrame?
	if inst:IsA("BasePart") then
		return inst.CFrame
	elseif inst:IsA("Model") then
		return inst:GetPivot()
	end
	return nil
end

-- Move `target` so its position is `point`, keeping its current orientation. Returns false if the
-- target cannot be positioned (not a BasePart or Model).
local function positionTarget(target: Instance, point: Vector3): boolean
	if target:IsA("BasePart") then
		target.Position = point
		return true
	elseif target:IsA("Model") then
		target:PivotTo(CFrame.new(point) * target:GetPivot().Rotation)
		return true
	end
	return false
end

local function runPlace(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if
		type(args.target) ~= "string"
		or type(args.anchor) ~= "string"
		or type(args.direction) ~= "string"
		or type(args.distance) ~= "number"
		or args.distance ~= args.distance -- NaN guard
	then
		return encodeResult({
			ok = false,
			error = "place_relative requires { target = <path>, anchor = <path>, direction = "
				.. "front|back|left|right|up|down, distance = <number> }",
		}),
			true
	end
	if Place.DIRS[args.direction] == nil then
		return encodeResult({
			ok = false,
			error = "direction must be one of front/back/left/right/up/down",
		}),
			true
	end

	local target, terr = Path.resolve(args.target)
	if target == nil then
		return encodeResult({ ok = false, error = "target: " .. tostring(terr) }), true
	end
	local anchor, aerr = Path.resolve(args.anchor)
	if anchor == nil then
		return encodeResult({ ok = false, error = "anchor: " .. tostring(aerr) }), true
	end

	-- Region guard (parallel writer): only the TARGET is mutated; the anchor is read-only. No-op for
	-- the serial parent (no context.writeRegion).
	local okRegion, regionErr = RegionGuard.check(target :: Instance, context)
	if not okRegion then
		return encodeResult({ ok = false, error = regionErr }), true
	end

	local aCF = anchorCFrame(anchor :: Instance)
	if aCF == nil then
		return encodeResult({
			ok = false,
			error = "anchor has no position (need a BasePart or Model)",
		}),
			true
	end
	local point = Place.offsetPoint(aCF, args.direction, args.distance)
	if point == nil then
		return encodeResult({
			ok = false,
			error = "direction must be one of front/back/left/right/up/down",
		}),
			true
	end

	-- In edit, wrap the move in an undoable recording; during a playtest apply directly.
	local rid: string? = nil
	if RunService:IsEdit() then
		rid = ChangeHistoryService:TryBeginRecording("Place " .. (target :: Instance).Name)
		if rid == nil then
			return encodeResult({ ok = false, error = "could not begin a change recording" }), true
		end
	end

	local okMove = false
	local okPcall = pcall(function()
		okMove = positionTarget(target :: Instance, point :: Vector3)
	end)

	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if okPcall and okMove
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not okPcall or not okMove then
		return encodeResult({
			ok = false,
			error = "target cannot be positioned (need a BasePart or Model)",
		}),
			true
	end

	return encodeResult({
		ok = true,
		target = Path.fullPath(target :: Instance),
		position = Serialize.encode(point),
	}),
		false
end

Place.descriptors = {
	{
		name = "place_relative",
		description = "Position an existing instance RELATIVE to an anchor instance — give a target, an "
			.. "anchor, a direction (front/back/left/right/up/down, relative to the ANCHOR's own "
			.. "orientation, so 'front' is the way the anchor faces), and a distance in studs. The tool "
			.. "computes the placement so you NEVER hand-write a CFrame or LookVector. Moves the target "
			.. "(keeps its current rotation). Works in edit and playtest; undoable in edit. e.g. place a "
			.. "ball 5 studs in front of the player: { target=<ball>, anchor=<player root>, "
			.. "direction='front', distance=5 }.",
		inputSchema = {
			type = "object",
			properties = {
				target = {
					type = "string",
					description = "Dot path to the instance to move (BasePart or Model).",
				},
				anchor = {
					type = "string",
					description = "Dot path to the reference instance (BasePart or Model).",
				},
				direction = {
					type = "string",
					description = "front | back | left | right | up | down (relative to the anchor's orientation).",
				},
				distance = { type = "number", description = "Studs from the anchor's center." },
			},
			required = { "target", "anchor", "direction", "distance" },
		},
		destructive = true,
		run = runPlace,
	},
} :: { Descriptor }

return Place
