--!strict
-- RegionGuard: confines a writer subagent's edits to its assigned region subtree. create_instance /
-- set_property call check() when context.writeRegion is set (parallel writer children). When it is
-- absent (the serial parent's normal writes), check() is a no-op, so existing behavior is unchanged.

local RegionGuard = {}

-- True if `target` is the region root itself or a descendant of it.
function RegionGuard.within(target: Instance, region: Instance): boolean
	return target == region or target:IsDescendantOf(region)
end

-- Gate a write at `target` against context.writeRegion. Returns (true) when no region is set, or the
-- target is within the region; (false, errMsg) when the target is outside the region.
function RegionGuard.check(target: Instance, context: any): (boolean, string?)
	local region = if type(context) == "table" then context.writeRegion else nil
	if region == nil then
		return true
	end
	if typeof(region) ~= "Instance" then
		return true
	end
	if RegionGuard.within(target, region) then
		return true
	end
	return false,
		"write outside your assigned region (" .. region:GetFullName() .. ") is not permitted"
end

return RegionGuard
