--!strict
-- ToolFactory: the handheld-item engine. PURE gripCFrame (intuitive offset/rot -> a Tool.Grip CFrame) is
-- unit-tested in ToolFactorySpec; the impure toolify/resolveRig/equip/applyGrip (build the Tool + Handle +
-- welds, equip on a rig, set the live grip) are added in Task 2 and are live-verified. Backs make_tool +
-- grip_tool. See docs/superpowers/specs/2026-06-24-handheld-item-creation-design.md.

local ToolFactory = {}

export type Vec3ish = { x: number?, y: number?, z: number? }
export type Rotish = { rx: number?, ry: number?, rz: number? }

-- ---- pure ----

-- Build a Tool.Grip CFrame from intuitive params: a translation (studs) then an XYZ rotation (degrees).
-- Missing fields default to 0 (identity = the Handle center in the palm). PURE -> unit-testable.
function ToolFactory.gripCFrame(offset: Vec3ish?, rot: Rotish?): CFrame
	local o = offset or {}
	local r = rot or {}
	local ox = if type(o.x) == "number" then o.x else 0
	local oy = if type(o.y) == "number" then o.y else 0
	local oz = if type(o.z) == "number" then o.z else 0
	local rx = if type(r.rx) == "number" then r.rx else 0
	local ry = if type(r.ry) == "number" then r.ry else 0
	local rz = if type(r.rz) == "number" then r.rz else 0
	return CFrame.new(ox, oy, oz) * CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
end

return ToolFactory
