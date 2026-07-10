--!strict
-- OracleChecks — the check registry: named deterministic measurements over the live
-- DataModel. Results are ALWAYS {verdict = PASS|FAIL|UNKNOWN, reason?, magnitudes = {...},
-- validity, context, cost_ms} — raw magnitudes ride every result (never bare booleans);
-- UNKNOWN never satisfies a suite (SP2 spec §2.1-2.5). Checks never throw: internal
-- errors become UNKNOWN(internal).
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Path = require(script.Parent.Path)
local OracleFrames = require(script.Parent.OracleFrames)

local M = {}

-- ---- geometry helpers (world-axis AABB; conservative for rotated parts) ----

local function partAABB(part: BasePart): (Vector3, Vector3)
	local cf, size = part.CFrame, part.Size
	local hx = math.abs(cf.RightVector.X) * size.X / 2 + math.abs(cf.UpVector.X) * size.Y / 2 + math.abs(cf.LookVector.X) * size.Z / 2
	local hy = math.abs(cf.RightVector.Y) * size.X / 2 + math.abs(cf.UpVector.Y) * size.Y / 2 + math.abs(cf.LookVector.Y) * size.Z / 2
	local hz = math.abs(cf.RightVector.Z) * size.X / 2 + math.abs(cf.UpVector.Z) * size.Y / 2 + math.abs(cf.LookVector.Z) * size.Z / 2
	local h = Vector3.new(hx, hy, hz)
	return cf.Position - h, cf.Position + h
end

local function collectParts(inst: Instance): { BasePart }
	local out = {}
	if inst:IsA("BasePart") then
		table.insert(out, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

local function unionAABB(parts: { BasePart }): (Vector3?, Vector3?)
	local mn, mx = nil, nil
	for _, p in parts do
		local a, b = partAABB(p)
		mn = if mn == nil then a else Vector3.new(math.min(mn.X, a.X), math.min(mn.Y, a.Y), math.min(mn.Z, a.Z))
		mx = if mx == nil then b else Vector3.new(math.max(mx.X, b.X), math.max(mx.Y, b.Y), math.max(mx.Z, b.Z))
	end
	return mn, mx
end

-- overlap per axis (positive = penetration, negative = separation)
local function axisOverlaps(minA: Vector3, maxA: Vector3, minB: Vector3, maxB: Vector3): Vector3
	return Vector3.new(
		math.min(maxA.X, maxB.X) - math.max(minA.X, minB.X),
		math.min(maxA.Y, maxB.Y) - math.max(minA.Y, minB.Y),
		math.min(maxA.Z, maxB.Z) - math.max(minA.Z, minB.Z)
	)
end

local function resolveParts(pathOrInst: any): ({ BasePart }?, string?)
	if typeof(pathOrInst) == "Instance" then
		local parts = collectParts(pathOrInst)
		if #parts == 0 then
			return nil, "no BaseParts under target"
		end
		return parts, nil
	end
	local inst, err = Path.resolve(tostring(pathOrInst))
	if inst == nil then
		return nil, err or ("not found: " .. tostring(pathOrInst))
	end
	local parts = collectParts(inst)
	if #parts == 0 then
		return nil, "no BaseParts under " .. tostring(pathOrInst)
	end
	return parts, nil
end

M.resolveParts = resolveParts
M.unionAABB = unionAABB
M.collectParts = collectParts

local function pass(mag: any): any
	return { verdict = "PASS", magnitudes = mag }
end
local function fail(reason: string, mag: any): any
	return { verdict = "FAIL", reason = reason, magnitudes = mag }
end
local function unknown(reason: string): any
	return { verdict = "UNKNOWN", reason = reason, magnitudes = {} }
end
M.pass, M.fail, M.unknown = pass, fail, unknown

-- ---- the registry ----

M.checks = {} :: { [string]: any }

local function register(name: string, validity: string, description: string, fn: (any) -> any, budget_ms: number?)
	M.checks[name] = { validity = validity, context = "edit", description = description, fn = fn, budget_ms = budget_ms or 2000 }
end
M.register = register

register("intersects", "EDIT_OK", "AABB intersection of two targets: {a, b} paths. PASS = intersecting.", function(args)
	local pa, ea = resolveParts(args.a)
	local pb, eb = resolveParts(args.b)
	if pa == nil or pb == nil then
		return unknown(ea or eb or "unresolved")
	end
	local minA, maxA = unionAABB(pa)
	local minB, maxB = unionAABB(pb)
	local ov = axisOverlaps(minA :: Vector3, maxA :: Vector3, minB :: Vector3, maxB :: Vector3)
	local depth = math.min(ov.X, ov.Y, ov.Z)
	local mag = { overlap_x = ov.X, overlap_y = ov.Y, overlap_z = ov.Z, penetration_depth = math.max(0, depth) }
	return if depth > 0 then pass(mag) else fail("not intersecting", mag)
end)

register("penetration_depth", "EDIT_OK", "Penetration depth in studs between {a, b}. PASS if depth <= {max_depth (default 0)}.", function(args)
	local pa, ea = resolveParts(args.a)
	local pb, eb = resolveParts(args.b)
	if pa == nil or pb == nil then
		return unknown(ea or eb or "unresolved")
	end
	local minA, maxA = unionAABB(pa)
	local minB, maxB = unionAABB(pb)
	local ov = axisOverlaps(minA :: Vector3, maxA :: Vector3, minB :: Vector3, maxB :: Vector3)
	local depth = math.max(0, math.min(ov.X, ov.Y, ov.Z))
	local maxDepth = tonumber(args.max_depth) or 0
	local mag = { penetration_depth = depth, max_allowed = maxDepth }
	return if depth <= maxDepth then pass(mag) else fail("penetrating " .. string.format("%.2f", depth) .. " studs", mag)
end)

register("gap_between", "EDIT_OK", "Euclidean AABB gap in studs between {a, b}. PASS if gap <= {max_gap (default 0.5)}.", function(args)
	local pa, ea = resolveParts(args.a)
	local pb, eb = resolveParts(args.b)
	if pa == nil or pb == nil then
		return unknown(ea or eb or "unresolved")
	end
	local minA, maxA = unionAABB(pa)
	local minB, maxB = unionAABB(pb)
	local ov = axisOverlaps(minA :: Vector3, maxA :: Vector3, minB :: Vector3, maxB :: Vector3)
	local sx, sy, sz = math.max(0, -ov.X), math.max(0, -ov.Y), math.max(0, -ov.Z)
	local gap = math.sqrt(sx * sx + sy * sy + sz * sz)
	local maxGap = tonumber(args.max_gap) or 0.5
	local mag = { gap_studs = gap, max_allowed = maxGap }
	return if gap <= maxGap then pass(mag) else fail("gap " .. string.format("%.2f", gap) .. " studs", mag)
end)

register("alignment", "EDIT_OK", "Angle between a frame dir of {target} (e.g. {dir='blade_dir'}) and a reference: {against='world_up'|{x,y,z}}. PASS if angle <= {max_deg (default 25)}. Reports end-to-end skew via {length}.", function(args)
	local inst = if typeof(args.target) == "Instance" then args.target else select(1, Path.resolve(tostring(args.target)))
	if inst == nil then
		return unknown("target not found")
	end
	local frame = select(1, OracleFrames.read(inst))
	local handle = OracleFrames.handleOf(inst)
	if frame == nil or handle == nil then
		return unknown("no frame/handle on target")
	end
	local dirName = tostring(args.dir or "blade_dir")
	local localDir = frame.dirs[dirName]
	if localDir == nil then
		return unknown("frame missing dir: " .. dirName .. " (stamp_frame first)")
	end
	local worldDir = handle.CFrame:VectorToWorldSpace(localDir).Unit
	local ref: Vector3
	if type(args.against) == "table" then
		local rawRef = Vector3.new(tonumber(args.against.x) or 0, tonumber(args.against.y) or 0, tonumber(args.against.z) or 0)
		if rawRef.Magnitude < 1e-4 then
			return unknown("zero reference vector")
		end
		ref = rawRef.Unit
	else
		ref = Vector3.new(0, 1, 0) -- world_up default
	end
	local dot = math.clamp(worldDir:Dot(ref), -1, 1)
	local angle = math.deg(math.acos(dot))
	local length = tonumber(args.length) or 0
	local maxDeg = tonumber(args.max_deg) or 25
	local mag = { angle_deg = angle, dot = dot, skew_studs = length * math.sin(math.rad(angle)) }
	return if angle <= maxDeg then pass(mag) else fail(dirName .. " is " .. string.format("%.1f", angle) .. " deg off", mag)
end)

register("scale_ratio", "EDIT_OK", "Longest world extent of {target} vs {expected (studs)} within {tolerance_frac (default 0.5)}.", function(args)
	local parts, err = resolveParts(args.target)
	if parts == nil then
		return unknown(err or "unresolved")
	end
	local mn, mx = unionAABB(parts)
	local ext = (mx :: Vector3) - (mn :: Vector3)
	local longest = math.max(ext.X, ext.Y, ext.Z)
	local expected = tonumber(args.expected) or 4
	local tol = tonumber(args.tolerance_frac) or 0.5
	local ratio = longest / expected
	local mag = { longest_studs = longest, expected = expected, ratio = ratio }
	return if ratio >= (1 - tol) and ratio <= (1 + tol) then pass(mag) else fail("scale off: " .. string.format("%.2f", longest) .. " studs vs expected " .. expected, mag)
end)

register("anchored_ok", "EDIT_MISLEADS", "For a Tool {target}: no anchored parts (anchored parts break welds at runtime). EDIT_MISLEADS: scripts can re-anchor at runtime.", function(args)
	local parts, err = resolveParts(args.target)
	if parts == nil then
		return unknown(err or "unresolved")
	end
	local anchored = {}
	for _, p in parts do
		if p.Anchored then
			table.insert(anchored, p.Name)
		end
	end
	local mag = { anchored_count = #anchored, anchored_parts = anchored }
	return if #anchored == 0 then pass(mag) else fail("anchored parts present", mag)
end)

register("frame_consistent", "EDIT_OK", "Anti-lie layer (spec §2.6): declared frame vs measured geometry for {target}. blade_dir must align with the blade-tagged parts' long axis; BladeTip near the extremum; Grip inside hilt geometry.", function(args)
	local inst = if typeof(args.target) == "Instance" then args.target else select(1, Path.resolve(tostring(args.target)))
	if inst == nil then
		return unknown("target not found")
	end
	local frame = select(1, OracleFrames.read(inst))
	local handle = OracleFrames.handleOf(inst)
	if frame == nil or handle == nil then
		return unknown("no frame/handle")
	end
	if #frame.missing > 0 then
		return unknown("frame incomplete: " .. table.concat(frame.missing, ", "))
	end
	local bladeParts = frame.roleParts.blade
	local hiltParts = frame.roleParts.hilt
	-- blade long axis in HANDLE space
	local mnL, mxL = nil, nil
	for _, p in bladeParts do
		local rel = handle.CFrame:ToObjectSpace(p.CFrame)
		local s = p.Size / 2
		local hx = math.abs(rel.RightVector.X) * s.X + math.abs(rel.UpVector.X) * s.Y + math.abs(rel.LookVector.X) * s.Z
		local hy = math.abs(rel.RightVector.Y) * s.X + math.abs(rel.UpVector.Y) * s.Y + math.abs(rel.LookVector.Y) * s.Z
		local hz = math.abs(rel.RightVector.Z) * s.X + math.abs(rel.UpVector.Z) * s.Y + math.abs(rel.LookVector.Z) * s.Z
		local lp = rel.Position
		local lo, hi = lp - Vector3.new(hx, hy, hz), lp + Vector3.new(hx, hy, hz)
		mnL = if mnL == nil then lo else Vector3.new(math.min(mnL.X, lo.X), math.min(mnL.Y, lo.Y), math.min(mnL.Z, lo.Z))
		mxL = if mxL == nil then hi else Vector3.new(math.max(mxL.X, hi.X), math.max(mxL.Y, hi.Y), math.max(mxL.Z, hi.Z))
	end
	local ext = (mxL :: Vector3) - (mnL :: Vector3)
	local axes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local exts = { ext.X, ext.Y, ext.Z }
	local bestI = 1
	for i = 2, 3 do
		if exts[i] > exts[bestI] then
			bestI = i
		end
	end
	local bladeDir = frame.dirs.blade_dir.Unit
	local axisDot = math.abs(bladeDir:Dot(axes[bestI]))
	-- tip near extremum along blade_dir
	local tip = frame.points.BladeTip
	local center = ((mnL :: Vector3) + (mxL :: Vector3)) / 2
	local maxAlong = 0
	for _, corner in { mnL :: Vector3, mxL :: Vector3 } do
		maxAlong = math.max(maxAlong, (corner - center):Dot(bladeDir))
	end
	local tipFrac = if maxAlong > 0 then math.clamp((tip - center):Dot(bladeDir) / maxAlong, -2, 2) else 0
	-- grip inside hilt AABB (expanded 25%)
	local mnH, mxH = unionAABB(hiltParts)
	local gripWorld = handle.CFrame:PointToWorldSpace(frame.points.Grip)
	local pad = ((mxH :: Vector3) - (mnH :: Vector3)).Magnitude * 0.25 + 0.25
	local inHilt = gripWorld.X >= (mnH :: Vector3).X - pad and gripWorld.X <= (mxH :: Vector3).X + pad
		and gripWorld.Y >= (mnH :: Vector3).Y - pad and gripWorld.Y <= (mxH :: Vector3).Y + pad
		and gripWorld.Z >= (mnH :: Vector3).Z - pad and gripWorld.Z <= (mxH :: Vector3).Z + pad
	local mag = { blade_axis_dot = axisDot, tip_extremum_frac = tipFrac, grip_in_hilt = inHilt }
	if axisDot < 0.85 then
		return fail("declared blade_dir disagrees with measured blade long axis (dot " .. string.format("%.2f", axisDot) .. ")", mag)
	end
	if tipFrac < 0.6 then
		return fail("declared BladeTip is not at the blade extremum (frac " .. string.format("%.2f", tipFrac) .. ")", mag)
	end
	if not inHilt then
		return fail("declared Grip lies outside hilt geometry", mag)
	end
	return pass(mag)
end)

register("grip_sane", "EDIT_OK", "For Tool {tool} on rig {rig (default workspace.AgentRig)}: the grip aligns Semantic_Grip to the hand and blade_dir points out of the fist. Magnitudes: grip_offset_studs, blade_up_angle_deg, hand_in_blade.", function(args)
	local tool = if typeof(args.tool) == "Instance" then args.tool else select(1, Path.resolve(tostring(args.tool)))
	if tool == nil or not tool:IsA("Tool") then
		return unknown("tool not found / not a Tool")
	end
	local rig = if args.rig ~= nil then select(1, Path.resolve(tostring(args.rig))) else workspace:FindFirstChild("AgentRig")
	if rig == nil then
		return unknown("no rig (spawn_rig first, or pass {rig})")
	end
	local hand = rig:FindFirstChild("RightHand", true)
	if hand == nil or not hand:IsA("BasePart") then
		return unknown("rig has no RightHand")
	end
	local frame = select(1, OracleFrames.read(tool))
	local handle = OracleFrames.handleOf(tool)
	if handle == nil or frame == nil or frame.dirs.blade_dir == nil or frame.points.Grip == nil then
		return unknown("tool frame incomplete (needs Grip point + blade_dir) — stamp_frame first")
	end
	-- handle-in-hand transform, mirroring ToolFactory.equip / the runtime RightGrip weld:
	-- handle.CFrame = hand.CFrame * C0 * Grip^-1, C0 = RightGripAttachment.CFrame (or identity)
	local att = hand:FindFirstChild("RightGripAttachment")
	local c0 = if att ~= nil and att:IsA("Attachment") then att.CFrame else CFrame.new()
	local handleInHand = c0 * tool.Grip:Inverse()
	local handWorld = hand.CFrame
	local handleWorld = handWorld * handleInHand
	local gripWorld = handleWorld:PointToWorldSpace(frame.points.Grip)
	local palmWorld = handWorld:PointToWorldSpace(c0.Position)
	local gripOffset = (gripWorld - palmWorld).Magnitude
	local bladeWorld = handleWorld:VectorToWorldSpace(frame.dirs.blade_dir).Unit
	local upAngle = math.deg(math.acos(math.clamp(bladeWorld:Dot(handWorld.UpVector), -1, 1)))
	-- hand center inside any blade-tagged part's AABB?
	local handIn = false
	if frame.roleParts.blade ~= nil then
		for _, p in frame.roleParts.blade do
			local lp = handleWorld:PointToObjectSpace(handWorld.Position) -- approx: handle-space
			local plocal = handle.CFrame:PointToObjectSpace(p.Position)
			local half = p.Size / 2
			if math.abs(lp.X - plocal.X) <= half.X and math.abs(lp.Y - plocal.Y) <= half.Y and math.abs(lp.Z - plocal.Z) <= half.Z then
				handIn = true
			end
		end
	end
	local maxOffset = tonumber(args.max_grip_offset) or 0.6
	local maxAngle = tonumber(args.max_blade_angle) or 35
	local mag = { grip_offset_studs = gripOffset, blade_up_angle_deg = upAngle, hand_in_blade = handIn }
	if gripOffset > maxOffset then
		return fail("Semantic_Grip sits " .. string.format("%.2f", gripOffset) .. " studs from the palm (max " .. maxOffset .. ")", mag)
	end
	if upAngle > maxAngle then
		return fail("blade_dir is " .. string.format("%.1f", upAngle) .. " deg off the fist-up axis (max " .. maxAngle .. ")", mag)
	end
	if handIn then
		return fail("the hand is inside blade geometry", mag)
	end
	return pass(mag)
end)

-- ---- rig + clip checks (kinematic; EDIT_OK via the Animator scrub used by capture_animation) ----

local AnimationClip = require(script.Parent.Parent.AnimationClip)

register("joint_census", "EDIT_OK", "Joint inventory for rig {rig}: Motor6D vs AnimationConstraint vs Weld counts (the T-pose trap detector).", function(args)
	local rig = if typeof(args.rig) == "Instance" then args.rig else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
	if rig == nil then
		return unknown("rig not found")
	end
	local motors, constraints, welds = {}, {}, {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			table.insert(motors, d.Name)
		elseif d:IsA("AnimationConstraint") then
			table.insert(constraints, d.Name)
		elseif d:IsA("Weld") or d:IsA("WeldConstraint") then
			table.insert(welds, d.Name)
		end
	end
	local mag = { motor6d = #motors, animation_constraints = #constraints, welds = #welds, motor_names = motors, constraint_names = constraints }
	if #motors > 0 and #constraints > 0 then
		return fail("MIXED rig: " .. #motors .. " Motor6D + " .. #constraints .. " AnimationConstraint (animations will half-play)", mag)
	end
	if #motors == 0 and #constraints == 0 then
		return fail("no animatable joints at all", mag)
	end
	return pass(mag)
end)

register("rig_channel_check", "EDIT_OK", "Clip {clip} joint names vs rig {rig} Motor6D channels: unmapped pose names = silently-dead animation channels.", function(args)
	local rig = if typeof(args.rig) == "Instance" then args.rig else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
	if rig == nil then
		return unknown("rig not found")
	end
	local saves = rig:FindFirstChild("AnimSaves")
	local ks = if saves ~= nil then saves:FindFirstChild(tostring(args.clip or "AgentClip")) else nil
	if ks == nil or not ks:IsA("KeyframeSequence") then
		return unknown("clip not found under rig/AnimSaves: " .. tostring(args.clip))
	end
	local channels = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 ~= nil then
			channels[d.Part1.Name] = true
		end
	end
	local unmapped = {}
	for _, kf in ks:GetKeyframes() do
		for _, pose in (kf :: Keyframe):GetDescendants() do
			if pose:IsA("Pose") and pose.Name ~= "HumanoidRootPart" and channels[pose.Name] == nil and pose.CFrame ~= CFrame.new() then
				if table.find(unmapped, pose.Name) == nil then
					table.insert(unmapped, pose.Name)
				end
			end
		end
	end
	local mag = { unmapped_poses = unmapped, channel_count = 0 }
	for _ in channels do
		mag.channel_count += 1
	end
	return if #unmapped == 0 then pass(mag) else fail("clip animates joints the rig lacks: " .. table.concat(unmapped, ", "), mag)
end)

-- Kinematic scrub shared by the clip checks: registers the clip, drives an Animator
-- through N sample times with StepAnimations(0), calls visit(t) per sample, and ALWAYS
-- restores Motor6D transforms (the capture_animation pattern, without screenshots).
local function scrubClip(rig: Model, clipName: string, samples: number, visit: (number) -> ()): string?
	local saves = rig:FindFirstChild("AnimSaves")
	local ks = if saves ~= nil then saves:FindFirstChild(clipName) else nil
	if ks == nil or not ks:IsA("KeyframeSequence") then
		return "clip not found under rig/AnimSaves: " .. clipName
	end
	local humanoid = rig:FindFirstChildWhichIsA("Humanoid")
	local animator = if humanoid ~= nil then humanoid:FindFirstChildWhichIsA("Animator") else rig:FindFirstChildWhichIsA("Animator", true)
	if animator == nil and humanoid ~= nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	if animator == nil then
		return "rig has no Humanoid/Animator"
	end
	local saved = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			saved[d] = d.Transform
		end
	end
	local id, rerr = AnimationClip.register(ks)
	if id == nil then
		return rerr or "clip registration failed"
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local track = animator:LoadAnimation(anim)
	track:Play(0)
	local deadline = os.clock() + 3
	while track.Length <= 0 and os.clock() < deadline do
		task.wait(0.05)
	end
	local err: string? = nil
	if track.Length <= 0 then
		err = "clip failed to load (Length 0)"
	else
		for i = 0, samples - 1 do
			local t = (i / math.max(1, samples - 1)) * track.Length
			track.TimePosition = t
			animator:StepAnimations(0)
			-- part CFrames/attachment WorldPositions update on the next frame step (the live-verified capture pattern settles after StepAnimations)
			RunService.Heartbeat:Wait()
			visit(t)
		end
	end
	track:Stop(0)
	-- destroy unconditionally: a stopped edit-mode track lingers and overrides manual poses (live-verified capture_animation pattern)
	animator:Destroy()
	for motor, transform in saved do
		motor.Transform = transform
	end
	return err
end

register("clip_arc_of", "EDIT_OK", "Samples clip {clip} on rig {rig} kinematically and traces the DECLARED Semantic_BladeTip of {tool}. Magnitudes: sweep_deg, path_studs, max_reach. PASS if sweep >= {min_sweep (default 60)}.", function(args)
	local rig = if typeof(args.rig) == "Instance" then args.rig else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
	local tool = if typeof(args.tool) == "Instance" then args.tool else select(1, Path.resolve(tostring(args.tool)))
	if rig == nil then
		return unknown("rig not found")
	end
	if tool == nil then
		return unknown("tool not found (the Tool must be equipped/welded on the rig for arc tracing)")
	end
	local handle = OracleFrames.handleOf(tool)
	local tipAtt = if handle ~= nil then handle:FindFirstChild("Semantic_BladeTip") else nil
	if tipAtt == nil or not tipAtt:IsA("Attachment") then
		return unknown("no Semantic_BladeTip attachment — stamp_frame first")
	end
	local root = rig:FindFirstChild("HumanoidRootPart") or rig.PrimaryPart
	if root == nil then
		return unknown("rig has no root part")
	end
	if not tool:IsDescendantOf(rig) then
		return unknown("tool is not equipped on the rig — grip_tool first")
	end
	local positions = {}
	local errMsg = scrubClip(rig :: Model, tostring(args.clip or "SwordSwing"), tonumber(args.samples) or 12, function(_t)
		table.insert(positions, (tipAtt :: Attachment).WorldPosition)
	end)
	if errMsg ~= nil then
		return unknown(errMsg)
	end
	local pathLen, maxReach = 0, 0
	for i, p in positions do
		if i > 1 then
			pathLen += (p - positions[i - 1]).Magnitude
		end
		maxReach = math.max(maxReach, (p - (root :: BasePart).Position).Magnitude)
	end
	local sweep = 0
	local rootPos = (root :: BasePart).Position
	for i = 1, #positions do
		if (positions[i] - rootPos).Magnitude >= 1e-3 then
			for j = i + 1, #positions do
				if (positions[j] - rootPos).Magnitude >= 1e-3 then
					local a = (positions[i] - rootPos).Unit
					local b = (positions[j] - rootPos).Unit
					sweep = math.max(sweep, math.deg(math.acos(math.clamp(a:Dot(b), -1, 1))))
				end
			end
		end
	end
	local minSweep = tonumber(args.min_sweep) or 60
	local mag = { sweep_deg = sweep, path_studs = pathLen, max_reach_studs = maxReach, samples = #positions }
	return if sweep >= minSweep then pass(mag) else fail("swing sweeps only " .. string.format("%.0f", sweep) .. " deg (min " .. minSweep .. ")", mag)
end, 20000)

register("clip_self_intersect", "EDIT_OK", "Samples clip {clip} on rig {rig}; at each pose, blade-tagged parts of {tool} vs the rig's torso/head: penetration beyond {max_depth (default 0.2)} studs FAILs with the offending time.", function(args)
	local rig = if typeof(args.rig) == "Instance" then args.rig else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
	local tool = if typeof(args.tool) == "Instance" then args.tool else select(1, Path.resolve(tostring(args.tool)))
	if rig == nil or tool == nil then
		return unknown("rig/tool not found")
	end
	local frame = select(1, OracleFrames.read(tool))
	if frame == nil or frame.roleParts.blade == nil then
		return unknown("no blade-tagged parts — stamp_frame first")
	end
	local bodyNames = { "UpperTorso", "LowerTorso", "Head", "Torso" }
	local body = {}
	for _, n in bodyNames do
		local p = rig:FindFirstChild(n, true)
		if p ~= nil and p:IsA("BasePart") then
			table.insert(body, p)
		end
	end
	if #body == 0 then
		return unknown("rig has no torso/head parts")
	end
	local hits = {}
	local maxDepth = tonumber(args.max_depth) or 0.2
	local errMsg = scrubClip(rig :: Model, tostring(args.clip or "SwordSwing"), tonumber(args.samples) or 12, function(t)
		for _, bp in frame.roleParts.blade do
			local mnA, mxA = partAABB(bp)
			for _, rp in body do
				local mnB, mxB = partAABB(rp)
				local ov = axisOverlaps(mnA, mxA, mnB, mxB)
				local depth = math.min(ov.X, ov.Y, ov.Z)
				if depth > maxDepth then
					table.insert(hits, { t = t, blade = bp.Name, body = rp.Name, depth = depth })
				end
			end
		end
	end)
	if errMsg ~= nil then
		return unknown(errMsg)
	end
	local mag = { intersections = hits, max_allowed_depth = maxDepth }
	return if #hits == 0 then pass(mag) else fail(#hits .. " blade-through-body sample(s), first at t=" .. string.format("%.2f", hits[1].t), mag)
end, 20000)

-- ---- declaration stubs (phase 2+): registered so suites/manifests can reference them;
-- each returns UNKNOWN until implemented. PLAY_ONLY stubs need a runtime twin. ----
local function declStub(name: string, validity: string)
	register(name, validity, "Declared; implemented in phase 2+.", function(_args)
		return unknown("declared; implemented in phase 2+")
	end)
end
declStub("played_arc_of", "PLAY_ONLY")
declStub("track_priority_audit", "PLAY_ONLY")
declStub("impulse_effective", "PLAY_ONLY")
declStub("stable_over", "PLAY_ONLY")
declStub("load_scale_probe", "PLAY_ONLY")
declStub("rig_uniform", "EDIT_OK")
declStub("clip_joint_mask", "EDIT_OK")

-- run(name, args) -> result (adds validity/context/cost_ms; never throws)
function M.run(name: string, args: any): any
	local entry = M.checks[name]
	if entry == nil then
		local names = {}
		for n in M.checks do
			table.insert(names, n)
		end
		table.sort(names)
		return {
			verdict = "UNKNOWN",
			reason = "unknown check: " .. tostring(name) .. " (available: " .. table.concat(names, ", ") .. ")",
			magnitudes = {},
			check = name,
			validity = "N/A",
			context = "edit",
			cost_ms = 0,
		}
	end
	local t0 = os.clock()
	local ok, result = pcall(entry.fn, if type(args) == "table" then args else {})
	if not ok then
		result = { verdict = "UNKNOWN", reason = "internal: " .. tostring(result), magnitudes = {} }
	end
	result.check = name
	result.validity = entry.validity
	result.context = entry.context
	result.cost_ms = math.floor((os.clock() - t0) * 1000 + 0.5)
	-- soft per-check time budget: an over-budget result degrades to UNKNOWN (magnitudes kept).
	local budget = entry.budget_ms or 2000
	if result.cost_ms > budget then
		result.reason = "timeout: took " .. result.cost_ms .. "ms (budget " .. budget .. "ms)"
		result.verdict = "UNKNOWN"
	end
	return result
end

return M
