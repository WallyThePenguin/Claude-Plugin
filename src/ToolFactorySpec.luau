--!strict
-- ToolFactorySpec: in-Studio self-test for the PURE ToolFactory.gripCFrame plus the articulated-chain
-- surface (fitChain + chain-aware toolify — instance fixtures, workspace-parented only where toolify
-- requires it, always cleaned up). Run via `require(script.ToolFactorySpec).run()` in
-- init.server.luau, OR from the bridge:
-- luau 'return tostring(require(script.Parent.ToolFactorySpec).run())'.

local ToolFactory = require(script.Parent.ToolFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("gripCFrame: identity default", function()
		local g = ToolFactory.gripCFrame(nil, nil)
		return g.Position == Vector3.new(0, 0, 0)
	end)

	add("gripCFrame: offset -> position", function()
		local g = ToolFactory.gripCFrame({ x = 1, y = 2, z = 3 }, nil)
		return g.Position == Vector3.new(1, 2, 3)
	end)

	add("gripCFrame: a Y rotation reorients (-Z maps to +/-X, Y unchanged)", function()
		local g = ToolFactory.gripCFrame(nil, { ry = 90 })
		local v = g:VectorToWorldSpace(Vector3.new(0, 0, -1))
		if math.abs(v.Y) > 0.01 then
			return false, "Y not preserved: " .. tostring(v.Y)
		end
		if math.abs(math.abs(v.X) - 1) > 0.01 or math.abs(v.Z) > 0.01 then
			return false, "did not map -Z to +/-X: " .. tostring(v)
		end
		return true
	end)

	add("gripCFrame: partial fields default to 0 (offset y only; rot rx only)", function()
		local g = ToolFactory.gripCFrame({ y = 5 }, { rx = 45 })
		if g.Position ~= Vector3.new(0, 5, 0) then
			return false, "offset partial wrong: " .. tostring(g.Position)
		end
		-- only rx set -> a pure X-axis rotation leaves the world X axis unchanged (ry/rz defaulted to 0)
		local vx = g:VectorToWorldSpace(Vector3.new(1, 0, 0))
		if math.abs(vx.X - 1) > 0.01 or math.abs(vx.Y) > 0.01 or math.abs(vx.Z) > 0.01 then
			return false, "rot not pure-X (ry/rz didn't default): " .. tostring(vx)
		end
		return true
	end)

	-- ---- articulated chain (weapon-as-limb, 2026-07-11) ----

	local function cframesClose(a: CFrame, b: CFrame, eps: number): boolean
		local ca = { a:GetComponents() }
		local cb = { b:GetComponents() }
		for i, v in ca do
			if math.abs(v - cb[i]) > eps then
				return false
			end
		end
		return true
	end

	-- Handle at origin + a 1x2x1 segment 2 studs above it, jointed by a default Motor6D.
	local function chainFixture(): (Model, BasePart, BasePart, Motor6D)
		local holder = Instance.new("Model")
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(0.4, 2, 0.4)
		handle.CFrame = CFrame.new(0, 0, 0)
		handle.Anchored = true
		handle.Parent = holder
		local seg = Instance.new("Part")
		seg.Name = "SegA"
		seg.Size = Vector3.new(1, 2, 1)
		seg.CFrame = CFrame.new(0, 2, 0)
		seg.Anchored = true
		seg.Parent = holder
		local m = Instance.new("Motor6D")
		m.Part0 = handle
		m.Part1 = seg
		m.Parent = handle
		return holder, handle, seg, m
	end

	add("fitChain: freezes built geometry (rest pose exact) with the hinge at the segment base", function()
		local holder, handle, seg, m = chainFixture()
		local fitted, names = ToolFactory.fitChain(holder)
		local ok, err = (function(): (boolean, string?)
			if fitted ~= 1 or #names ~= 1 then
				return false, "expected 1 fitted/1 name, got " .. fitted .. "/" .. #names
			end
			-- rest-pose kinematics: Part1.CFrame == Part0.CFrame * C0 * C1^-1 (Transform identity)
			local rest = handle.CFrame * m.C0 * m.C1:Inverse()
			if not cframesClose(rest, seg.CFrame, 1e-4) then
				return false, "rest pose not preserved: " .. tostring(rest)
			end
			-- hinge at the segment's near face toward Part0: Part0 center (0,0,0) is 2 below the
			-- segment center, clamped into the 1x2x1 half-box -> (0,-1,0) = the base face center
			if (m.C1.Position - Vector3.new(0, -1, 0)).Magnitude > 1e-4 then
				return false, "hinge not at segment base: " .. tostring(m.C1.Position)
			end
			-- default-named joint renamed after Part1 (pose channels address joints by name)
			if m.Name ~= "SegA" then
				return false, "joint not renamed after Part1: " .. m.Name
			end
			if m:GetAttribute(ToolFactory.CHAIN_FITTED_ATTR) ~= true then
				return false, "SAChainFitted attribute missing"
			end
			return true
		end)()
		holder:Destroy()
		return ok, err
	end)

	add("fitChain: idempotent (second call fits nothing, keeps the fit)", function()
		local holder, _handle, _seg, m = chainFixture()
		ToolFactory.fitChain(holder)
		local c0, c1 = m.C0, m.C1
		local fitted2, names2 = ToolFactory.fitChain(holder)
		local ok, err = (function(): (boolean, string?)
			if fitted2 ~= 0 then
				return false, "second fit should fit 0, got " .. fitted2
			end
			if #names2 ~= 1 then
				return false, "chain names should still enumerate, got " .. #names2
			end
			if m.C0 ~= c0 or m.C1 ~= c1 then
				return false, "refit mutated an already-fitted joint"
			end
			return true
		end)()
		holder:Destroy()
		return ok, err
	end)

	add("fitChain: an authored (non-identity) C0/C1 is respected, only stamped", function()
		local holder, _handle, _seg, m = chainFixture()
		local authored = CFrame.new(0, 1, 0) * CFrame.Angles(math.rad(15), 0, 0)
		m.C0 = authored
		local fitted = ToolFactory.fitChain(holder)
		local ok, err = (function(): (boolean, string?)
			if fitted ~= 0 then
				return false, "authored joint must not be re-fit, got fitted=" .. fitted
			end
			if not cframesClose(m.C0, authored, 1e-6) then
				return false, "authored C0 was clobbered"
			end
			if m:GetAttribute(ToolFactory.CHAIN_FITTED_ATTR) ~= true then
				return false, "authored joint should still be stamped as fitted"
			end
			return true
		end)()
		holder:Destroy()
		return ok, err
	end)

	add("fitChain: flips a tip-down joint so the channel is drivable (review fix)", function()
		local holder, handle, seg, m = chainFixture()
		-- author the joint BACKWARDS: Part0 = the segment, Part1 = the handle (tip-down)
		m.Part0 = seg
		m.Part1 = handle
		local fitted, names, flipped = ToolFactory.fitChain(holder, handle)
		local ok, err = (function(): (boolean, string?)
			if flipped ~= 1 then
				return false, "expected 1 flip, got " .. flipped
			end
			if m.Part0 ~= handle or m.Part1 ~= seg then
				return false, "joint not re-pointed hilt-outward"
			end
			if fitted ~= 1 or #names ~= 1 or names[1] ~= "SegA" then
				return false, "flip did not feed the normal fit/rename path"
			end
			local rest = handle.CFrame * m.C0 * m.C1:Inverse()
			if not cframesClose(rest, seg.CFrame, 1e-4) then
				return false, "rest pose broken by the flip: " .. tostring(rest)
			end
			return true
		end)()
		holder:Destroy()
		return ok, err
	end)

	add("fitChain: heals an internal reserved-name joint; skips the real external grip", function()
		local holder, handle = chainFixture()
		-- rename the internal chain joint to the reserved grip name (builder mistake)
		local internal = handle:FindFirstChildWhichIsA("Motor6D") :: Motor6D
		internal.Name = "AgentEditGrip"
		-- a REAL grip shape: joint named AgentEditGrip parented inside the holder but with
		-- Part0 OUTSIDE it (the rig's hand) — must be left alone entirely
		local hand = Instance.new("Part")
		hand.Name = "RightHand"
		hand.Anchored = true
		local realGrip = Instance.new("Motor6D")
		realGrip.Name = "AgentEditGrip"
		realGrip.Part0 = hand
		realGrip.Part1 = handle
		realGrip.Parent = handle
		local fitted, names = ToolFactory.fitChain(holder, handle)
		local ok, err = (function(): (boolean, string?)
			if internal.Name ~= "SegA" then
				return false, "internal reserved-name joint not healed: " .. internal.Name
			end
			if fitted ~= 1 or #names ~= 1 then
				return false, string.format("expected the healed joint fit once, got fitted=%d names=%d", fitted, #names)
			end
			if internal:GetAttribute(ToolFactory.CHAIN_FITTED_ATTR) ~= true then
				return false, "healed joint not stamped as fitted"
			end
			if realGrip.Name ~= "AgentEditGrip" or realGrip.C0 ~= CFrame.identity then
				return false, "the real external grip joint was touched"
			end
			-- the healed joint must have a REAL fit (identity C0 here = the collapse trap)
			if internal.C0 == CFrame.identity then
				return false, "healed joint left identity C0 — would collapse at unanchor"
			end
			return true
		end)()
		holder:Destroy()
		hand:Destroy()
		return ok, err
	end)

	add("toolify: chained parts keep their Motor6D (no weld), loose parts weld", function()
		local holder, handle, seg = chainFixture()
		holder.Name = "ChainToolFixture"
		local guard = Instance.new("Part")
		guard.Name = "Guard"
		guard.Size = Vector3.new(1, 0.2, 1)
		guard.CFrame = CFrame.new(0, 1, 0)
		guard.Anchored = true
		guard.Parent = holder
		holder.Parent = workspace
		local tool, err, chainCount = ToolFactory.toolify(holder, handle, "ChainToolFixture")
		local ok, why = (function(): (boolean, string?)
			if tool == nil then
				return false, "toolify failed: " .. tostring(err)
			end
			local t = tool :: Tool
			if chainCount ~= 1 then
				return false, "expected chainCount 1, got " .. tostring(chainCount)
			end
			-- the segment must NOT be welded to the Handle
			for _, d in t:GetDescendants() do
				if d:IsA("WeldConstraint") and (d.Part1 == seg or d.Part0 == seg) then
					return false, "chained segment was WeldConstraint'd (would freeze the joint)"
				end
			end
			-- the chain joint survives, parented under Part0, fit + named after Part1. (Search
			-- Motor6Ds explicitly: the SEGMENT PART is also named SegA and FindFirstChild would
			-- return it first — joint names and part names are separate namespaces to the Animator.)
			local joint: Motor6D? = nil
			for _, d in t:GetDescendants() do
				if d:IsA("Motor6D") and d.Name == "SegA" then
					joint = d
				end
			end
			if joint == nil then
				return false, "chain Motor6D missing after toolify"
			end
			if (joint :: Motor6D).Parent ~= t:FindFirstChild("Handle") then
				return false, "chain joint not re-homed under its Part0"
			end
			if (joint :: Motor6D):GetAttribute(ToolFactory.CHAIN_FITTED_ATTR) ~= true then
				return false, "chain joint not fit at toolify time"
			end
			-- GEOMETRY survives (live-caught collapse 2026-07-11): unanchoring a Motor6D's parts
			-- makes the edit assembly solver enforce C0/C1 — an identity fit (fit AFTER unanchor)
			-- snaps every segment onto the Handle. The built 2-stud offset must survive toolify.
			local handlePart = t:FindFirstChild("Handle")
			if handlePart == nil or not handlePart:IsA("BasePart") then
				return false, "tool has no Handle part"
			end
			local offset = (seg.CFrame.Position - (handlePart :: BasePart).CFrame.Position).Magnitude
			if math.abs(offset - 2) > 0.05 then
				return false, string.format("segment collapsed: %.2f studs from Handle (built at 2)", offset)
			end
			if (joint :: Motor6D).C0 == CFrame.identity then
				return false, "chain joint C0 is identity — fit ran against collapsed geometry"
			end
			-- the loose Guard part IS welded
			local guardWelded = false
			for _, d in t:GetDescendants() do
				if d:IsA("WeldConstraint") and d.Part1 == guard then
					guardWelded = true
				end
			end
			if not guardWelded then
				return false, "loose part lost its weld"
			end
			return true
		end)()
		if tool ~= nil then
			(tool :: Tool):Destroy()
		end
		return ok, why
	end)

	return cases
end

-- (ok, failureSummary) — the second return lets the bridge caller SEE which case failed
-- (Studio Output print/warn lines don't ride back over the luau channel).
function M.run(): (boolean, string)
	local cases = buildCases()
	local passed = 0
	local failures: { string } = {}
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[ToolFactorySpec] PASS " .. c.name)
		else
			table.insert(failures, c.name .. (if err then " — " .. err else ""))
			warn("[ToolFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[ToolFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases, ("%d/%d passed"):format(passed, #cases)
		.. (if #failures > 0 then "; FAIL: " .. table.concat(failures, " | ") else "")
end

return M
