--!strict
-- Place: the place_relative tool — position an existing instance relative to an anchor instance by an
-- anchor-LOCAL direction + distance, so the agent never hand-computes facing/CFrame math. PURE math
-- (offsetPoint/DIRS) is unit-tested in PlaceSpec; the impure apply (resolve, region guard, undoable
-- recording) mirrors Create.luau/Properties.luau and is live-verified.
--
-- Tools/ submodule: reaches top-level Serialize via script.Parent.Parent and its Tools siblings
-- (Path, RegionGuard) via script.Parent.

local Place = {}

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

return Place
