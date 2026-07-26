--!strict
-- OracleChecks — the check registry: named deterministic measurements over the live
-- DataModel. Results are ALWAYS {verdict = PASS|FAIL|UNKNOWN, reason?, magnitudes = {...},
-- validity, context, cost_ms} — raw magnitudes ride every result (never bare booleans);
-- UNKNOWN never satisfies a suite (SP2 spec §2.1-2.5). Checks never throw: internal
-- errors become UNKNOWN(internal).
local RunService = game:GetService("RunService")

local CaptureCore = require(script.Parent.CaptureCore)
local Path = require(script.Parent.Path)
local OracleFrames = require(script.Parent.OracleFrames)
local ToolFactory = require(script.Parent.Parent.ToolFactory)

local M = {}

-- ---- geometry helpers (world-axis AABB; conservative for rotated parts) ----

local function partAABB(part: BasePart): (Vector3, Vector3)
	local cf, size = part.CFrame, part.Size
	local hx = math.abs(cf.RightVector.X) * size.X / 2
		+ math.abs(cf.UpVector.X) * size.Y / 2
		+ math.abs(cf.LookVector.X) * size.Z / 2
	local hy = math.abs(cf.RightVector.Y) * size.X / 2
		+ math.abs(cf.UpVector.Y) * size.Y / 2
		+ math.abs(cf.LookVector.Y) * size.Z / 2
	local hz = math.abs(cf.RightVector.Z) * size.X / 2
		+ math.abs(cf.UpVector.Z) * size.Y / 2
		+ math.abs(cf.LookVector.Z) * size.Z / 2
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
		mn = if mn == nil
			then a
			else Vector3.new(math.min(mn.X, a.X), math.min(mn.Y, a.Y), math.min(mn.Z, a.Z))
		mx = if mx == nil
			then b
			else Vector3.new(math.max(mx.X, b.X), math.max(mx.Y, b.Y), math.max(mx.Z, b.Z))
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
local function unknown(reason: string, mag: any?): any
	-- magnitudes ride EVERY result (SP2 §2.1) — an UNKNOWN that already measured something
	-- should still hand the numbers over rather than swallow them.
	return { verdict = "UNKNOWN", reason = reason, magnitudes = mag or {} }
end
M.pass, M.fail, M.unknown = pass, fail, unknown

-- ---- the registry ----

M.checks = {} :: { [string]: any }

local function register(
	name: string,
	validity: string,
	description: string,
	fn: (any) -> any,
	budget_ms: number?
)
	M.checks[name] = {
		validity = validity,
		context = "edit",
		description = description,
		fn = fn,
		budget_ms = budget_ms or 2000,
	}
end
M.register = register

register(
	"intersects",
	"EDIT_OK",
	"AABB intersection of two targets: {a, b} paths. PASS = intersecting.",
	function(args)
		local pa, ea = resolveParts(args.a)
		local pb, eb = resolveParts(args.b)
		if pa == nil or pb == nil then
			return unknown(ea or eb or "unresolved")
		end
		local minA, maxA = unionAABB(pa)
		local minB, maxB = unionAABB(pb)
		local ov = axisOverlaps(minA :: Vector3, maxA :: Vector3, minB :: Vector3, maxB :: Vector3)
		local depth = math.min(ov.X, ov.Y, ov.Z)
		local mag = {
			overlap_x = ov.X,
			overlap_y = ov.Y,
			overlap_z = ov.Z,
			penetration_depth = math.max(0, depth),
		}
		return if depth > 0 then pass(mag) else fail("not intersecting", mag)
	end
)

register(
	"penetration_depth",
	"EDIT_OK",
	"Penetration depth in studs between {a, b}. PASS if depth <= {max_depth (default 0)}.",
	function(args)
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
		return if depth <= maxDepth
			then pass(mag)
			else fail("penetrating " .. string.format("%.2f", depth) .. " studs", mag)
	end
)

register(
	"gap_between",
	"EDIT_OK",
	"Euclidean AABB gap in studs between {a, b}. PASS if gap <= {max_gap (default 0.5)}.",
	function(args)
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
		return if gap <= maxGap
			then pass(mag)
			else fail("gap " .. string.format("%.2f", gap) .. " studs", mag)
	end
)

register(
	"alignment",
	"EDIT_OK",
	"Angle between a frame dir of {target} (e.g. {dir='blade_dir'}) and a reference: {against='world_up'|{x,y,z}}. PASS if angle <= {max_deg (default 25)}. Reports end-to-end skew via {length}.",
	function(args)
		local inst = if typeof(args.target) == "Instance"
			then args.target
			else select(1, Path.resolve(tostring(args.target)))
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
			local rawRef = Vector3.new(
				tonumber(args.against.x) or 0,
				tonumber(args.against.y) or 0,
				tonumber(args.against.z) or 0
			)
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
		local mag =
			{ angle_deg = angle, dot = dot, skew_studs = length * math.sin(math.rad(angle)) }
		return if angle <= maxDeg
			then pass(mag)
			else fail(dirName .. " is " .. string.format("%.1f", angle) .. " deg off", mag)
	end
)

register(
	"scale_ratio",
	"EDIT_OK",
	"Longest world extent of {target} vs {expected (studs)} within {tolerance_frac (default 0.5)}.",
	function(args)
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
		return if ratio >= (1 - tol) and ratio <= (1 + tol)
			then pass(mag)
			else fail(
				"scale off: " .. string.format("%.2f", longest) .. " studs vs expected " .. expected,
				mag
			)
	end
)

register(
	"mesh_persisted",
	"EDIT_OK",
	"Upload-era persistence for every MeshPart under {target}: PASS arms are (a) finalized — real non-empty MeshId (durable asset), (b) pending upload — SAMeshAssetPending=true + SAMeshAssetId attributes (CreateAssetAsync in flight, confirm_mesh will finalize), or (c) legacy draft — SALocalMesh + MeshData child + deployed ServerScriptService.SAMeshRebuildRuntime (PROVISIONAL pass: draft-only, not shipped). A bare sessionless MeshPart = FAIL (invisible in Play). Closes the audit-caught gap where an 8/8 suite green-lit an invisible weapon (RETRO-proposed 2026-07-10; upload-era arms 2026-07-11).",
	function(args)
		local parts, err = resolveParts(args.target)
		if parts == nil then
			return unknown(err or "unresolved")
		end
		local meshParts, finalized, pendingUpload, draftLocal = 0, 0, 0, 0
		local firstNaked: string? = nil
		for _, p in parts do
			if p:IsA("MeshPart") then
				meshParts += 1
				if p.MeshId ~= "" then
					finalized += 1
				elseif
					p:GetAttribute("SAMeshAssetPending") == true
					and p:GetAttribute("SAMeshAssetId") ~= nil
				then
					pendingUpload += 1
				elseif
					p:GetAttribute("SALocalMesh") == true
					and p:FindFirstChild("MeshData") ~= nil
				then
					draftLocal += 1
				elseif firstNaked == nil then
					firstNaked = p.Name
				end
			end
		end
		local runtime = game:GetService("ServerScriptService")
			:FindFirstChild("SAMeshRebuildRuntime")
		local mag = {
			mesh_parts = meshParts,
			finalized = finalized,
			pending_upload = pendingUpload,
			draft_local = draftLocal,
			naked = meshParts - finalized - pendingUpload - draftLocal,
			rebuild_runtime_deployed = runtime ~= nil,
		}
		if firstNaked ~= nil then
			return fail(
				"MeshPart '"
					.. firstNaked
					.. "' has an empty MeshId, no recorded upload, and no local-rebuild data — INVISIBLE in Play",
				mag
			)
		end
		if draftLocal > 0 and runtime == nil then
			return fail(
				draftLocal
					.. " draft mesh(es) (SALocalMesh) but ServerScriptService.SAMeshRebuildRuntime is NOT deployed — invisible in Play",
				mag
			)
		end
		if draftLocal > 0 then
			-- provisional: renders in Play via the rebuild runtime, but is NOT a durable shipped asset
			local r = pass(mag)
			r.reason = "provisional: "
				.. draftLocal
				.. " draft-only mesh(es) (SALocalMesh, not shipped) — upload via save_mesh, finalize via confirm_mesh"
			return r
		end
		return pass(mag)
	end
)

register(
	"anchored_ok",
	"EDIT_MISLEADS",
	"For a Tool {target}: no anchored parts (anchored parts break welds at runtime). EDIT_MISLEADS: scripts can re-anchor at runtime.",
	function(args)
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
	end
)

register(
	"frame_consistent",
	"EDIT_OK",
	"Anti-lie layer (spec §2.6): declared frame vs measured geometry for {target}. blade_dir must align with the blade-tagged parts' long axis; BladeTip near the extremum; Grip inside hilt geometry.",
	function(args)
		local inst = if typeof(args.target) == "Instance"
			then args.target
			else select(1, Path.resolve(tostring(args.target)))
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
			local hx = math.abs(rel.RightVector.X) * s.X
				+ math.abs(rel.UpVector.X) * s.Y
				+ math.abs(rel.LookVector.X) * s.Z
			local hy = math.abs(rel.RightVector.Y) * s.X
				+ math.abs(rel.UpVector.Y) * s.Y
				+ math.abs(rel.LookVector.Y) * s.Z
			local hz = math.abs(rel.RightVector.Z) * s.X
				+ math.abs(rel.UpVector.Z) * s.Y
				+ math.abs(rel.LookVector.Z) * s.Z
			local lp = rel.Position
			local lo, hi = lp - Vector3.new(hx, hy, hz), lp + Vector3.new(hx, hy, hz)
			mnL = if mnL == nil
				then lo
				else Vector3.new(
					math.min(mnL.X, lo.X),
					math.min(mnL.Y, lo.Y),
					math.min(mnL.Z, lo.Z)
				)
			mxL = if mxL == nil
				then hi
				else Vector3.new(
					math.max(mxL.X, hi.X),
					math.max(mxL.Y, hi.Y),
					math.max(mxL.Z, hi.Z)
				)
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
		local tipFrac = if maxAlong > 0
			then math.clamp((tip - center):Dot(bladeDir) / maxAlong, -2, 2)
			else 0
		-- grip inside hilt AABB (expanded 25%)
		local mnH, mxH = unionAABB(hiltParts)
		local gripWorld = handle.CFrame:PointToWorldSpace(frame.points.Grip)
		local pad = ((mxH :: Vector3) - (mnH :: Vector3)).Magnitude * 0.25 + 0.25
		local inHilt = gripWorld.X >= (mnH :: Vector3).X - pad
			and gripWorld.X <= (mxH :: Vector3).X + pad
			and gripWorld.Y >= (mnH :: Vector3).Y - pad
			and gripWorld.Y <= (mxH :: Vector3).Y + pad
			and gripWorld.Z >= (mnH :: Vector3).Z - pad
			and gripWorld.Z <= (mxH :: Vector3).Z + pad
		local mag = { blade_axis_dot = axisDot, tip_extremum_frac = tipFrac, grip_in_hilt = inHilt }
		if axisDot < 0.85 then
			return fail(
				"declared blade_dir disagrees with measured blade long axis (dot "
					.. string.format("%.2f", axisDot)
					.. ")",
				mag
			)
		end
		if tipFrac < 0.6 then
			return fail(
				"declared BladeTip is not at the blade extremum (frac "
					.. string.format("%.2f", tipFrac)
					.. ")",
				mag
			)
		end
		if not inHilt then
			return fail("declared Grip lies outside hilt geometry", mag)
		end
		return pass(mag)
	end
)

register(
	"grip_sane",
	"EDIT_OK",
	"For Tool {tool} on rig {rig (default workspace.AgentRig)}: the grip aligns Semantic_Grip to the hand and blade_dir/edge_dir match ToolFactory's HOLD frame (blade out the knuckles, edge toward the palm — the fitter's own contract, one source of truth), and the declared blade centerline stays clear of the arm. Magnitudes: grip_offset_studs, blade_hold_angle_deg, edge_hold_angle_deg (nil unless edge_dir declared), blade_up_angle_deg (retired fist-up measure, informational), hand_in_blade, blade_in_arm_studs.",
	function(args)
		local tool = if typeof(args.tool) == "Instance"
			then args.tool
			else select(1, Path.resolve(tostring(args.tool)))
		if tool == nil or not tool:IsA("Tool") then
			return unknown("tool not found / not a Tool")
		end
		local rig = if args.rig ~= nil
			then select(1, Path.resolve(tostring(args.rig)))
			else workspace:FindFirstChild("AgentRig")
		if rig == nil then
			return unknown("no rig (spawn_rig first, or pass {rig})")
		end
		local hand = rig:FindFirstChild("RightHand", true)
		if hand == nil or not hand:IsA("BasePart") then
			return unknown("rig has no RightHand")
		end
		local frame = select(1, OracleFrames.read(tool))
		local handle = OracleFrames.handleOf(tool)
		if
			handle == nil
			or frame == nil
			or frame.dirs.blade_dir == nil
			or frame.points.Grip == nil
		then
			return unknown(
				"tool frame incomplete (needs Grip point + blade_dir) — stamp_frame first"
			)
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
		-- The HOLD convention is OWNED by ToolFactory (user-picked 2026-07-12c: blade out the
		-- hand's front, edge toward the palm) — the oracle asserts the fitter's OWN contract,
		-- never a private axis. Pre-07-12c this check asserted fist-up and FAILed every
		-- correctly-held weapon at 90.0 deg (stale-vocabulary bug, live-caught 2026-07-25).
		local holdBladeWorld = handWorld:VectorToWorldSpace(ToolFactory.HOLD_BLADE_DIR).Unit
		local holdAngle = math.deg(math.acos(math.clamp(bladeWorld:Dot(holdBladeWorld), -1, 1)))
		local upAngle = math.deg(math.acos(math.clamp(bladeWorld:Dot(handWorld.UpVector), -1, 1)))
		-- Roll constraint (the "on its side" class): only asserted when edge_dir is declared.
		local edgeAngle: number? = nil
		if frame.dirs.edge_dir ~= nil then
			local edgeWorld = handleWorld:VectorToWorldSpace(frame.dirs.edge_dir).Unit
			local holdEdgeWorld = handWorld:VectorToWorldSpace(ToolFactory.HOLD_EDGE_DIR).Unit
			edgeAngle = math.deg(math.acos(math.clamp(edgeWorld:Dot(holdEdgeWorld), -1, 1)))
		end
		-- hand center inside any blade-tagged part's AABB? ONLY assertable when the blade role
		-- names parts DISJOINT from the hilt role — on a single-part tool (blade role == hilt
		-- role == the whole mesh) the fist is inside "blade geometry" by construction and the
		-- test is vacuous-true (live-caught on the ForgeLongsword suite 2026-07-25). The
		-- centerline blade_in_arm test below stays the honest single-part proxy.
		local rolesDisjoint = true
		if frame.roleParts.blade ~= nil and frame.roleParts.hilt ~= nil then
			for _, bp in frame.roleParts.blade do
				for _, hp in frame.roleParts.hilt do
					if bp == hp then
						rolesDisjoint = false
					end
				end
			end
		end
		local handIn = false
		if frame.roleParts.blade ~= nil and rolesDisjoint then
			for _, p in frame.roleParts.blade do
				local lp = handleWorld:PointToObjectSpace(handWorld.Position) -- approx: handle-space
				local plocal = handle.CFrame:PointToObjectSpace(p.Position)
				local half = p.Size / 2
				if
					math.abs(lp.X - plocal.X) <= half.X
					and math.abs(lp.Y - plocal.Y) <= half.Y
					and math.abs(lp.Z - plocal.Z) <= half.Z
				then
					handIn = true
				end
			end
		end
		-- blade-vs-arm clearance at the COMPUTED grip pose (human-caught gap 2026-07-10: a grip can
		-- measure 0 studs / 0 deg and still run the blade straight through the forearm at the hold
		-- pose). Sample the DECLARED centerline (Grip -> BladeTip) and count samples inside the arm
		-- parts' oriented boxes; the magnitude is embedded LENGTH in studs. Fist region excluded.
		local bladeInArm = 0
		local tipPoint = frame.points.BladeTip
		if tipPoint ~= nil then
			local armParts = {}
			for _, armName in { "RightUpperArm", "RightLowerArm" } do
				local ap = rig:FindFirstChild(armName, true)
				if ap ~= nil and ap:IsA("BasePart") then
					table.insert(armParts, ap)
				end
			end
			local samples = 12
			local inside = 0
			for i = 1, samples do
				local t = 0.15 + 0.85 * (i - 1) / (samples - 1)
				local world =
					handleWorld:PointToWorldSpace((frame.points.Grip :: Vector3):Lerp(tipPoint, t))
				for _, ap in armParts do
					local lp = ap.CFrame:PointToObjectSpace(world)
					local half = ap.Size / 2
					if
						math.abs(lp.X) <= half.X
						and math.abs(lp.Y) <= half.Y
						and math.abs(lp.Z) <= half.Z
					then
						inside += 1
						break
					end
				end
			end
			bladeInArm = (inside / samples) * (tipPoint - frame.points.Grip).Magnitude * 0.85
		end
		local maxOffset = tonumber(args.max_grip_offset) or 0.6
		local maxAngle = tonumber(args.max_blade_angle) or 35
		local maxEdge = tonumber(args.max_edge_angle) or 40
		local maxInArm = tonumber(args.max_blade_in_arm) or 1.0
		local mag = {
			grip_offset_studs = gripOffset,
			blade_hold_angle_deg = holdAngle,
			edge_hold_angle_deg = edgeAngle,
			blade_up_angle_deg = upAngle, -- informational: the RETIRED fist-up measure (pre-07-12c learnings cite it)
			hand_in_blade = if rolesDisjoint
				then handIn
				else "not-assertable (blade role == hilt role: single-part tool)",
			blade_in_arm_studs = bladeInArm,
		}
		if gripOffset > maxOffset then
			return fail(
				"Semantic_Grip sits "
					.. string.format("%.2f", gripOffset)
					.. " studs from the palm (max "
					.. maxOffset
					.. ")",
				mag
			)
		end
		if holdAngle > maxAngle then
			return fail(
				"blade_dir is "
					.. string.format("%.1f", holdAngle)
					.. " deg off the HOLD blade axis (out the knuckles; max "
					.. maxAngle
					.. ")",
				mag
			)
		end
		if edgeAngle ~= nil and edgeAngle > maxEdge then
			return fail(
				"edge_dir is "
					.. string.format("%.1f", edgeAngle)
					.. " deg off the HOLD edge axis (toward the palm; max "
					.. maxEdge
					.. ") — the 'on its side' class",
				mag
			)
		end
		if handIn then
			return fail("the hand is inside blade geometry", mag)
		end
		if bladeInArm > maxInArm then
			return fail(
				string.format("%.2f", bladeInArm)
					.. " studs of blade centerline run INSIDE the arm (max "
					.. maxInArm
					.. ")",
				mag
			)
		end
		return pass(mag)
	end
)

-- ---- tool_clip_current: grip-stamp staleness (the 2026-07-11 stale-clip saga) ----
-- When a Tool's Grip changes, every clip authored against the old grip is visually invalid
-- (live-caught: after the grip fix, the embedded Anims/use still held the blade through the
-- character's body). The stamp is a compact exact serialization of Tool.Grip; authoring tools
-- (grip_tool re-fits / bind_animation) should write it onto each Anims/* clip as attribute
-- SAClipGripStamp via M.stampToolClips.

-- Canonical stamp: all 12 CFrame components at 3 decimals (a 1-degree rotation moves sin
-- components by ~0.017 — well above the quantum). "-0.000" normalizes to "0.000".
function M.gripStampOf(grip: CFrame): string
	local comps = { grip:GetComponents() }
	local out = table.create(#comps)
	for i, v in comps do
		local s = string.format("%.3f", v)
		if s == "-0.000" then
			s = "0.000"
		end
		out[i] = s
	end
	return table.concat(out, ",")
end

-- Pure verdict core (selftest-covered): a mismatch FAILs even when other clips are unstamped
-- (a proven-stale clip is stale); otherwise any unstamped clip fails OPEN as UNKNOWN.
function M.clipStampVerdict(currentStamp: string, clips: { { name: string, stamp: string? } }): any
	if #clips == 0 then
		return unknown("tool has no Anims/* clips — nothing to check (bind_animation first)")
	end
	local matching, mismatched, unstamped = {}, {}, {}
	for _, c in clips do
		if c.stamp == nil then
			table.insert(unstamped, c.name)
		elseif c.stamp == currentStamp then
			table.insert(matching, c.name)
		else
			table.insert(mismatched, c.name)
		end
	end
	local mag = {
		clips_total = #clips,
		matching = matching,
		mismatched = mismatched,
		unstamped = unstamped,
		current_stamp = currentStamp,
	}
	if #mismatched > 0 then
		return fail(
			"clip "
				.. table.concat(mismatched, ", ")
				.. " authored against a different Grip (stamp mismatch) — re-author with the current grip",
			mag
		)
	end
	if #unstamped > 0 then
		local r = unknown(
			"clips carry no grip stamp (authored before stamping existed); re-author or stamp to activate: "
				.. table.concat(unstamped, ", ")
		)
		r.magnitudes = mag
		return r
	end
	return pass(mag)
end

-- Fix-forward helper, NOT a check (the registry has no fix-forward convention — checks stay
-- read-only measurements): writes SAClipGripStamp = current-grip-stamp onto every Anims/*
-- KeyframeSequence. grip_tool (after a Grip write) and bind_animation (after authoring against
-- the live grip) should call this; until they do, call it manually via run_luau:
--   require(script.Parent.Tools.OracleChecks).stampToolClips(game.StarterPack.Sword)
function M.stampToolClips(toolOrPath: any): any
	local tool = if typeof(toolOrPath) == "Instance"
		then toolOrPath
		else select(1, Path.resolve(tostring(toolOrPath)))
	if tool == nil or not tool:IsA("Tool") then
		return { ok = false, error = "tool not found / not a Tool" }
	end
	local anims = tool:FindFirstChild("Anims")
	if anims == nil then
		return { ok = false, error = "tool has no Anims folder (bind_animation first)" }
	end
	local stamp = M.gripStampOf(tool.Grip)
	local stamped = {}
	for _, c in anims:GetChildren() do
		if c:IsA("KeyframeSequence") then
			c:SetAttribute("SAClipGripStamp", stamp)
			table.insert(stamped, c.Name)
		end
	end
	return { ok = true, count = #stamped, stamped = stamped, stamp = stamp }
end

register(
	"tool_clip_current",
	"EDIT_OK",
	"For Tool {tool}: every embedded Anims/* KeyframeSequence must carry attribute SAClipGripStamp equal to the CURRENT Tool.Grip stamp — a Grip change invalidates every clip authored against the old grip (the stale-clip trap: a green suite while Anims/use swings the blade through the body). UNKNOWN (fail-open) when clips are unstamped; stamp via OracleChecks.stampToolClips or re-author. BLINDSPOT: asserts STALENESS only, not visual correctness of the motion.",
	function(args)
		local tool = if typeof(args.tool) == "Instance"
			then args.tool
			else select(1, Path.resolve(tostring(args.tool)))
		if tool == nil or not tool:IsA("Tool") then
			return unknown("tool not found / not a Tool")
		end
		local anims = tool:FindFirstChild("Anims")
		if anims == nil then
			return unknown("tool has no Anims folder — nothing to check (bind_animation first)")
		end
		local clips = {}
		for _, c in anims:GetChildren() do
			if c:IsA("KeyframeSequence") then
				local raw = c:GetAttribute("SAClipGripStamp")
				table.insert(
					clips,
					{ name = c.Name, stamp = if raw ~= nil then tostring(raw) else nil }
				)
			end
		end
		return M.clipStampVerdict(M.gripStampOf(tool.Grip), clips)
	end
)

-- ---- rig + clip checks (kinematic; EDIT_OK via the Animator scrub used by capture_animation) ----

local AnimationClip = require(script.Parent.Parent.AnimationClip)

register(
	"joint_census",
	"EDIT_OK",
	"Joint inventory for rig {rig}: BODY Motor6D vs AnimationConstraint vs Weld counts (the T-pose trap detector). WEAPON joints are FIRST-CLASS and reported separately as weapon_motor6d/weapon_motor_names (AgentEditGrip + any Motor6D inside a Tool — an articulated weapon's own joint chain). FAILs on duplicate pose-channel (Part1) names: the Animator matches poses by connected-part NAME, so a duplicate silently clobbers a channel.",
	function(args)
		local rig = if typeof(args.rig) == "Instance"
			then args.rig
			else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
		if rig == nil then
			return unknown("rig not found")
		end
		local motors, weaponMotors, constraints, welds = {}, {}, {}, {}
		local channelCounts: { [string]: number } = {}
		for _, d in rig:GetDescendants() do
			if d:IsA("Motor6D") then
				-- weapon channel = the edit grip + Tool-internal chain joints (weapon-as-limb)
				if d.Name == "AgentEditGrip" or d:FindFirstAncestorWhichIsA("Tool") ~= nil then
					table.insert(weaponMotors, d.Name)
				else
					table.insert(motors, d.Name)
				end
				if d.Part0 ~= nil and d.Part1 ~= nil then
					local n = (d.Part1 :: BasePart).Name
					channelCounts[n] = (channelCounts[n] or 0) + 1
				end
			elseif d:IsA("AnimationConstraint") then
				table.insert(constraints, d.Name)
			elseif d:IsA("Weld") or d:IsA("WeldConstraint") then
				table.insert(welds, d.Name)
			end
		end
		local dupes = {}
		for n, c in channelCounts do
			if c > 1 then
				table.insert(dupes, n)
			end
		end
		table.sort(dupes)
		local mag = {
			motor6d = #motors,
			weapon_motor6d = #weaponMotors,
			animation_constraints = #constraints,
			welds = #welds,
			motor_names = motors,
			weapon_motor_names = weaponMotors,
			constraint_names = constraints,
			duplicate_channels = dupes,
		}
		if #dupes > 0 then
			return fail(
				"duplicate animation channel name(s): "
					.. table.concat(dupes, ", ")
					.. " — the Animator matches poses by connected-part NAME; a duplicate silently clobbers one channel. Most likely cause: a STALE previously-equipped Tool still under the rig — release/evict it (grip_tool {release:true}); rename parts only for a genuine same-name collision inside ONE weapon",
				mag
			)
		end
		if (#motors + #weaponMotors) > 0 and #constraints > 0 then
			return fail(
				"MIXED rig: "
					.. (#motors + #weaponMotors)
					.. " Motor6D + "
					.. #constraints
					.. " AnimationConstraint (animations will half-play)",
				mag
			)
		end
		if #motors == 0 and #weaponMotors == 0 and #constraints == 0 then
			return fail("no animatable joints at all", mag)
		end
		return pass(mag)
	end
)

register(
	"rig_channel_check",
	"EDIT_OK",
	"Clip {clip} joint names vs rig {rig} Motor6D channels: unmapped pose names = silently-dead animation channels.",
	function(args)
		local rig = if typeof(args.rig) == "Instance"
			then args.rig
			else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
		if rig == nil then
			return unknown("rig not found")
		end
		local clipName = tostring(args.clip or "SwordSwing")
		local saves = rig:FindFirstChild("AnimSaves")
		local ks = if saves ~= nil then saves:FindFirstChild(clipName) else nil
		if ks == nil or not ks:IsA("KeyframeSequence") then
			return unknown("clip not found under rig/AnimSaves: " .. clipName)
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
				if
					pose:IsA("Pose")
					and pose.Name ~= "HumanoidRootPart"
					and channels[pose.Name] == nil
					and pose.CFrame ~= CFrame.new()
				then
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
		return if #unmapped == 0
			then pass(mag)
			else fail(
				"clip animates joints the rig lacks: " .. table.concat(unmapped, ", "),
				mag
			)
	end
)

-- Kinematic scrub shared by the clip checks: registers the clip, drives an Animator
-- through N sample times with StepAnimations(0), calls visit(t) per sample, and ALWAYS
-- restores Motor6D transforms (the capture_animation pattern, without screenshots).
local function scrubClip(
	rig: Model,
	clipName: string,
	samples: number,
	visit: (number) -> ()
): string?
	local saves = rig:FindFirstChild("AnimSaves")
	local ks = if saves ~= nil then saves:FindFirstChild(clipName) else nil
	if ks == nil or not ks:IsA("KeyframeSequence") then
		return "clip not found under rig/AnimSaves: " .. clipName
	end
	local humanoid = rig:FindFirstChildWhichIsA("Humanoid")
	local animator = if humanoid ~= nil
		then humanoid:FindFirstChildWhichIsA("Animator")
		else rig:FindFirstChildWhichIsA("Animator", true)
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
	local animParent = animator.Parent
	animator:Destroy()
	for motor, transform in saved do
		motor.Transform = transform
	end
	-- Restoring Transforms alone does NOT move PART CFRAMES in edit (the applyPose fact) —
	-- without a joint solve the rig stays frozen at the LAST SCRUBBED POSE for every check
	-- that runs after this one (live-caught 2026-07-25: capture_vantage in the suite read
	-- the follow-through pose and FAILed while passing standalone at rest).
	local fresh = Instance.new("Animator")
	fresh.Parent = animParent
	fresh:StepAnimations(0)
	fresh:Destroy()
	return err
end

register(
	"clip_arc_of",
	"EDIT_MISLEADS",
	"Samples clip {clip} on rig {rig} kinematically and traces the DECLARED Semantic_BladeTip of {tool}. CLASS-AWARE: a SLASH is asserted on angular sweep >= {min_sweep (default 60)}; a THRUST on linear extension >= {min_extension (default 1.0)} studs AND {min_axial_frac (default 0.5)} of the tip's path lying ALONG the blade axis (a thrust's payoff is reach, not sweep — a healthy fencing thrust failed the slash prior at 34 deg). Class = {motion_class} arg, else the clip's SAClipMotionClass attribute, else slash. Declaring the WRONG class FAILS (a slash's tip travels across its own axis, so it cannot pass the axial bar) — the declaration can never rescue a bad clip. All magnitudes ride every result regardless of class. EDIT_MISLEADS: the StepAnimations(0) scrub bypasses the runtime Animator (fade/blend/priority/locomotion) — needs the played_arc_of run twin.",
	function(args)
		local rig = if typeof(args.rig) == "Instance"
			then args.rig
			else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
		local tool = if typeof(args.tool) == "Instance"
			then args.tool
			else select(1, Path.resolve(tostring(args.tool)))
		if rig == nil then
			return unknown("rig not found")
		end
		if tool == nil then
			return unknown(
				"tool not found (the Tool must be equipped/welded on the rig for arc tracing)"
			)
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
		local gripAtt = if handle ~= nil then handle:FindFirstChild("Semantic_Grip") else nil
		local positions = {}
		local gripPositions = {}
		local clipName = tostring(args.clip or "SwordSwing")
		local times = {}
		-- 24 samples (not 12): axial travel is sampling-SENSITIVE — the chord between widely
		-- spaced samples of a ROTATING blade understates axial travel, and the measured value
		-- kept moving with density (0.374 @12 -> 0.247 @90 on one clip). Denser is truer; 24
		-- is stable enough to compare clips and still inside the check's time budget.
		local errMsg = scrubClip(rig :: Model, clipName, tonumber(args.samples) or 24, function(t)
			table.insert(positions, (tipAtt :: Attachment).WorldPosition)
			table.insert(times, t)
			if gripAtt ~= nil and gripAtt:IsA("Attachment") then
				table.insert(gripPositions, (gripAtt :: Attachment).WorldPosition)
			end
		end)
		if errMsg ~= nil then
			return unknown(errMsg)
		end
		local pathLen, maxReach = 0, 0
		local minReach = math.huge
		for i, p in positions do
			if i > 1 then
				pathLen += (p - positions[i - 1]).Magnitude
			end
			local reach = (p - (root :: BasePart).Position).Magnitude
			maxReach = math.max(maxReach, reach)
			minReach = math.min(minReach, reach)
		end
		-- THRUST instruments. extension = how far the tip travels AWAY from the body over the
		-- clip (a thrust's payoff); axial travel = how much of the tip's path runs ALONG the
		-- blade's own axis, which is what separates a stab from a cut (a slash's tip travels
		-- ACROSS its axis, so a mis-declared slash cannot pass).
		--
		-- The verdict keys on the PEAK WINDOW, not the whole-clip average: an attack clip is
		-- wind-up + committed beat + recovery, and the arcs on either side dilute the beat to
		-- nothing (a purpose-generated fencing lunge averaged 0.25 whole-clip — indistinguishable
		-- from a flourish — while its extension beat is the part that matters). Whole-clip stays
		-- as a reported magnitude; it answers "is this clip ALL thrust", not "does it CONTAIN one".
		local extension = if minReach < math.huge then maxReach - minReach else 0
		local axialSteps, lenSteps = {}, {}
		if #gripPositions == #positions then
			for i = 1, #positions - 1 do
				local blade = positions[i] - gripPositions[i]
				local d = positions[i + 1] - positions[i]
				if blade.Magnitude > 1e-3 and d.Magnitude > 1e-4 then
					table.insert(axialSteps, math.abs(d:Dot(blade.Unit)))
					table.insert(lenSteps, d.Magnitude)
				else
					table.insert(axialSteps, 0)
					table.insert(lenSteps, 0)
				end
			end
		end
		local axialSum, pathSum = 0, 0
		for i, a in axialSteps do
			axialSum += a
			pathSum += lenSteps[i]
		end
		local axialFrac = if pathSum > 0 then axialSum / pathSum else nil
		-- Best contiguous window covering `axial_window_frac` of the clip (default 25%).
		local windowFrac = math.clamp(tonumber(args.axial_window_frac) or 0.25, 0.05, 1)
		local win = math.max(2, math.floor(#axialSteps * windowFrac + 0.5))
		local peakFrac, peakAt = nil :: number?, 0
		if #axialSteps >= win and pathSum > 0 then
			for s = 1, #axialSteps - win + 1 do
				local wa, wl = 0, 0
				for i = s, s + win - 1 do
					wa += axialSteps[i]
					wl += lenSteps[i]
				end
				-- Ignore windows where the tip barely moves: a stationary hold is trivially
				-- "axial" (0/0-ish) and would hand any clip a free pass.
				if wl > 0.15 * pathSum * (win / #axialSteps) then
					local f = wa / wl
					if peakFrac == nil or f > peakFrac then
						peakFrac = f
						peakAt = times[s] or 0
					end
				end
			end
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
		local minExtension = tonumber(args.min_extension) or 1.0
		local minAxial = tonumber(args.min_axial_frac) or 0.5
		-- The class is DECLARED (arg, else the clip's own attribute, else slash) — never
		-- inferred from the numbers: a check that picks its own bar can rubber-stamp any
		-- clip by choosing whichever class it already passes.
		local saves = rig:FindFirstChild("AnimSaves")
		local ks = if saves ~= nil then saves:FindFirstChild(clipName) else nil
		local declared = args.motion_class
			or (if ks ~= nil then ks:GetAttribute("SAClipMotionClass") else nil)
		local class = string.lower(tostring(declared or "slash"))
		if class ~= "slash" and class ~= "thrust" then
			return unknown("unknown motion_class '" .. class .. "' (use slash|thrust)")
		end
		local mag = {
			motion_class = class,
			class_source = if args.motion_class ~= nil
				then "arg"
				elseif declared ~= nil then "clip attribute SAClipMotionClass"
				else "default",
			sweep_deg = sweep,
			min_sweep = minSweep,
			extension_studs = extension,
			min_extension = minExtension,
			axial_peak_frac = peakFrac, -- the verdict's instrument (best committed beat)
			min_axial_frac = minAxial,
			axial_peak_at = peakAt,
			axial_window_frac = windowFrac,
			axial_frac = axialFrac, -- whole-clip average (reported, NOT the bar)
			path_studs = pathLen,
			max_reach_studs = maxReach,
			samples = #positions,
		}
		if class == "thrust" then
			if axialFrac == nil or peakFrac == nil then
				return unknown(
					"thrust needs the Semantic_Grip attachment (and a moving tip) to measure axial travel — stamp_frame first",
					mag
				)
			end
			if extension < minExtension then
				return fail(
					"thrust extends the tip only "
						.. string.format("%.2f", extension)
						.. " studs (min "
						.. minExtension
						.. ")",
					mag
				)
			end
			if peakFrac < minAxial then
				return fail(
					"no committed thrust beat: the most axial "
						.. string.format("%.0f%%", windowFrac * 100)
						.. " window runs only "
						.. string.format("%.2f", peakFrac)
						.. " along the blade axis (min "
						.. minAxial
						.. ") — this reads as a CUT, not a thrust; check the declared class",
					mag
				)
			end
			return pass(mag)
		end
		return if sweep >= minSweep
			then pass(mag)
			else fail(
				"swing sweeps only "
					.. string.format("%.0f", sweep)
					.. " deg (min "
					.. minSweep
					.. ")",
				mag
			)
	end,
	20000
)

register(
	"weapon_channel_of",
	"EDIT_OK",
	"Clip {clip} on rig {rig} actually DRIVES the weapon channel: >=2 keyframes must contain a Pose named after an AgentEditGrip Part1 (usually 'Handle') nested under the grip's Part0 Pose AND connected to the keyframe's ROOT pose chain (unrooted stray subtrees are ignored — the Animator never applies them), AND the grip rotation must sweep > {min_swept_deg (default 10)} across keyframes. Catches scoped clips saved without add_keyframe {weapon=true} (a swing whose sword never moves). CHAIN-AWARE (weapon-as-limb): articulated joints reachable from the grip's Part1 (snake sword / flail segments) are measured first-class — magnitudes chain_joints/chain_channels/chain_posed_channels/chain_swept_deg. DEFAULT ESCALATION: when the rig's weapon HAS a chain, a clip that leaves the chain entirely UNKEYED FAILs (keyed-but-static chains pass — idle clips are legitimate). {require_chain=true} additionally demands EVERY chain channel keyed in >=2 keyframes and a chain sweep > min_swept_deg (use for strike clips). BLINDSPOT: default does not assert chain SWEEP.",
	function(args)
		local rig = if typeof(args.rig) == "Instance"
			then args.rig
			else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
		if rig == nil then
			return unknown("rig not found")
		end
		local clipName = tostring(args.clip or "SwordSwing")
		local saves = rig:FindFirstChild("AnimSaves")
		local ks = if saves ~= nil then saves:FindFirstChild(clipName) else nil
		if ks == nil or not ks:IsA("KeyframeSequence") then
			return unknown("clip not found under rig/AnimSaves: " .. clipName)
		end
		-- grip pairs from the live rig: Part0 name -> set of Part1 names (AgentEditGrip Motor6Ds; the
		-- Animator matches poses by CONNECTED PART NAMES, so the clip must nest Part1 under Part0)
		local gripPairs: { [string]: { [string]: boolean } } = {}
		local gripCount = 0
		local gripHandles: { Instance } = {}
		for _, d in rig:GetDescendants() do
			if
				d:IsA("Motor6D")
				and d.Name == "AgentEditGrip"
				and d.Part0 ~= nil
				and d.Part1 ~= nil
			then
				local p0 = (d.Part0 :: BasePart).Name
				if gripPairs[p0] == nil then
					gripPairs[p0] = {}
				end
				gripPairs[p0][(d.Part1 :: BasePart).Name] = true
				gripCount += 1
				table.insert(gripHandles, d.Part1 :: Instance)
			end
		end
		if gripCount == 0 then
			return unknown(
				"no AgentEditGrip Motor6D under rig — grip_tool first (the weapon channel needs the edit grip joint)"
			)
		end
		-- the ARTICULATED CHAIN: (Part0 name -> Part1 name) pairs reachable from each grip's Part1
		-- through further Motor6Ds (segments inside the Tool) — each is its own pose channel
		local chainPairs: { [string]: { [string]: boolean } } = {}
		local chainChannels: { string } = {}
		do
			local childrenOf = AnimationClip.adjacency(rig)
			local seen: { [Instance]: boolean } = {}
			local queue: { Instance } = {}
			for _, h in gripHandles do
				if not seen[h] then
					seen[h] = true
					table.insert(queue, h)
				end
			end
			local head = 1
			while head <= #queue do
				local part = queue[head]
				head += 1
				for _, m in (childrenOf[part] or {}) do
					local child = (m :: Motor6D).Part1 :: Instance
					if not seen[child] then
						seen[child] = true
						local p0n = part.Name
						if chainPairs[p0n] == nil then
							chainPairs[p0n] = {}
						end
						chainPairs[p0n][child.Name] = true
						table.insert(chainChannels, child.Name)
						table.insert(queue, child)
					end
				end
			end
		end
		-- ROOT-CONNECTIVITY (review-caught): the Animator only applies a Pose nested under the
		-- keyframe's root-pose chain (live-verified doctrine in AnimationClip.buildScopedPoses) —
		-- a stray subtree parented directly under the Keyframe never plays, so it must not
		-- satisfy this check. A matched pose counts only when walking up its Pose ancestors
		-- terminates at a top-level Pose named after the rig root, directly under the Keyframe.
		local rootPart = AnimationClip.rigRoot(rig)
		if rootPart == nil then
			return unknown("rig has no Motor6D root — cannot judge pose-tree rooting")
		end
		local rootName = (rootPart :: Instance).Name
		local function rootConnected(pose: Instance, kf: Instance): boolean
			local cur: Instance = pose
			while cur.Parent ~= nil and (cur.Parent :: Instance):IsA("Pose") do
				cur = cur.Parent :: Instance
			end
			return cur.Parent == kf and cur.Name == rootName
		end
		local keyframes = ks:GetKeyframes()
		local handlePoses = 0
		local handleCFs: { CFrame } = {}
		local chainCFs: { [string]: { CFrame } } = {}
		for _, kf in keyframes do
			local gripSeen = false
			local chainSeen: { [string]: boolean } = {}
			for _, pose in (kf :: Keyframe):GetDescendants() do
				local parent = pose.Parent
				if
					pose:IsA("Pose")
					and parent ~= nil
					and parent:IsA("Pose")
					and rootConnected(pose, kf)
				then
					if
						not gripSeen
						and gripPairs[parent.Name] ~= nil
						and gripPairs[parent.Name][pose.Name] == true
					then
						gripSeen = true
						handlePoses += 1
						table.insert(handleCFs, pose.CFrame)
					elseif
						chainPairs[parent.Name] ~= nil
						and chainPairs[parent.Name][pose.Name] == true
						and not chainSeen[pose.Name]
					then
						chainSeen[pose.Name] = true
						if chainCFs[pose.Name] == nil then
							chainCFs[pose.Name] = {}
						end
						table.insert(chainCFs[pose.Name], pose.CFrame)
					end
				end
			end
		end
		local function maxPairwiseDeg(cfs: { CFrame }): number
			local best = 0
			for i = 1, #cfs do
				for j = i + 1, #cfs do
					local _axis, angle = (cfs[i].Rotation:Inverse() * cfs[j].Rotation):ToAxisAngle()
					best = math.max(best, math.deg(angle))
				end
			end
			return best
		end
		local swept = maxPairwiseDeg(handleCFs)
		local chainSwept = 0
		local chainPosedChannels = 0
		for _, cfs in chainCFs do
			if #cfs >= 2 then
				chainPosedChannels += 1
			end
			chainSwept = math.max(chainSwept, maxPairwiseDeg(cfs))
		end
		local minSwept = tonumber(args.min_swept_deg) or 10
		local mag = {
			keyframes = #keyframes,
			handle_poses = handlePoses,
			swept_deg = swept,
			chain_joints = #chainChannels,
			chain_channels = chainChannels,
			chain_posed_channels = chainPosedChannels,
			chain_swept_deg = chainSwept,
		}
		if handlePoses < 2 then
			return fail(
				"weapon channel present in only "
					.. handlePoses
					.. "/"
					.. #keyframes
					.. " keyframes (need >=2 root-connected — save with add_keyframe {weapon=true})",
				mag
			)
		end
		if swept <= minSwept and args.allow_static_grip ~= true then
			-- {allow_static_grip=true}: a RETARGETED full-body clip (Kimodo/SOMA) legitimately keeps
			-- the grip channel static — the sword rides the ARM, it never rotates in the fist
			-- (live-caught: 90 identity Handle poses on SwordSlash, 2026-07-25). The strict default
			-- stays for AUTHORED weapon-swing clips (the forgot-weapon=true defect class).
			return fail(
				"weapon channel exists but the grip rotation sweeps only "
					.. string.format("%.1f", swept)
					.. " deg across keyframes (min "
					.. minSwept
					.. ") — a static Handle pose (retargeted held-weapon clip? pass allow_static_grip=true)",
				mag
			)
		end
		-- DEFAULT ESCALATION (review-caught: suites could never assert the chain): when the rig's
		-- weapon IS articulated, a clip that leaves the chain entirely UNKEYED fails by default —
		-- that is the weaponChildNames-regression / forgot-weapon=true defect class. Keyed-but-
		-- static chains still pass (an idle hold clip legitimately keeps segments straight).
		if #chainChannels > 0 and chainPosedChannels == 0 then
			return fail(
				"the weapon has an articulated chain ("
					.. #chainChannels
					.. " joint(s)) but NO chain channel is keyed in this clip — save with add_keyframe {weapon=true} (it keys the whole chain)",
				mag
			)
		end
		if args.require_chain == true then
			if #chainChannels == 0 then
				return fail(
					"require_chain: the rig has NO articulated chain joints beyond the grip (segments must be Motor6D-jointed inside the Tool)",
					mag
				)
			end
			if chainPosedChannels < #chainChannels then
				return fail(
					"require_chain: only "
						.. chainPosedChannels
						.. "/"
						.. #chainChannels
						.. " chain channels are keyed in >=2 keyframes — a weapon is a LIMB; key every segment (add_keyframe poses + weapon=true)",
					mag
				)
			end
			if chainSwept <= minSwept then
				return fail(
					"require_chain: all chain channels are keyed but sweep only "
						.. string.format("%.1f", chainSwept)
						.. " deg across keyframes (min "
						.. minSwept
						.. ") — static segment poses",
					mag
				)
			end
		end
		return pass(mag)
	end
)

register(
	"clip_self_intersect",
	"EDIT_OK",
	"Samples clip {clip} on rig {rig}; at each pose, blade-vs-torso/head AND the declared blade centerline vs the ARM parts (embedded length beyond {max_blade_in_arm (default: max(0.3, 1.5 centerline-sample quanta of the declared blade) — one grazing sample passes at every blade length)} studs) FAIL with the offending time. TWO body modes: blade-role parts DISJOINT from hilt -> part-AABB penetration beyond {max_depth (default 0.2)}; single-part tools (blade==hilt==whole mesh) -> the DECLARED centerline embedded in body parts beyond {max_blade_in_body (default 0.3)} studs (whole-sword world-AABBs phantom-penetrate mid-swing — live-caught 2026-07-25). Magnitude `mode` names which ran.",
	function(args)
		local rig = if typeof(args.rig) == "Instance"
			then args.rig
			else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
		local tool = if typeof(args.tool) == "Instance"
			then args.tool
			else select(1, Path.resolve(tostring(args.tool)))
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
		-- arms are checked by the DECLARED centerline (exact point-in-OBB, like grip_sane's static
		-- check — AABBs on rotated limbs over-trigger for the wielding arm), the torso/head by AABB
		-- depth as before. Human-caught gap 2026-07-10: a swing can drive the blade through an arm.
		local handle = OracleFrames.handleOf(tool)
		local armParts = {}
		for _, n in
			{
				"RightUpperArm",
				"RightLowerArm",
				"LeftUpperArm",
				"LeftLowerArm",
				"Right Arm",
				"Left Arm",
			}
		do
			local p = rig:FindFirstChild(n, true)
			if p ~= nil and p:IsA("BasePart") then
				table.insert(armParts, p)
			end
		end
		local gripPt, tipPt = frame.points.Grip, frame.points.BladeTip
		local hits = {}
		local maxDepth = tonumber(args.max_depth) or 0.2
		-- Gate philosophy: ONE grazing centerline sample passes, sustained overlap fails
		-- (the 1.0 default let a capture-visible 0.44-stud forearm pass silently —
		-- audit-caught 2026-07-25). The embedded measure is LENGTH-weighted (one sample =
		-- bladeLen·0.85/12 studs), so a fixed floor gives long blades ZERO tolerated
		-- samples: the 4.3-stud rapier's single near-hilt sample at the raise (fist at the
		-- shoulder, eyes-checked clean) read 0.3046 > 0.3. Default = 1.5 sample-quanta of
		-- the DECLARED blade, floored at 0.3 — every original 2-sample flaw still fails.
		local quantum = if gripPt ~= nil and tipPt ~= nil
			then ((tipPt :: Vector3) - (gripPt :: Vector3)).Magnitude * 0.85 / 12
			else 0.2
		local maxInArm = tonumber(args.max_blade_in_arm) or math.max(0.3, 1.5 * quantum)
		local armWorst = { studs = 0, t = 0, part = "" }
		-- Single-part tools (blade role == hilt role): the whole-sword world-AABB is meaningless
		-- mid-swing (a diagonal sword inflates into phantom torso "penetration" — live-caught 15
		-- false hits on the longsword slash, 2026-07-25). Fall back to the DECLARED centerline
		-- vs body parts (point-in-OBB, embedded studs), same instrument as the arm test.
		local bladeDisjoint = true
		if frame.roleParts.hilt ~= nil then
			for _, bp in frame.roleParts.blade do
				for _, hp in frame.roleParts.hilt do
					if bp == hp then
						bladeDisjoint = false
					end
				end
			end
		end
		local maxInBody = tonumber(args.max_blade_in_body) or 0.3
		local bodyWorst = { studs = 0, t = 0, part = "" }
		local errMsg = scrubClip(
			rig :: Model,
			tostring(args.clip or "SwordSwing"),
			tonumber(args.samples) or 12,
			function(t)
				if bladeDisjoint then
					for _, bp in frame.roleParts.blade do
						local mnA, mxA = partAABB(bp)
						for _, rp in body do
							local mnB, mxB = partAABB(rp)
							local ov = axisOverlaps(mnA, mxA, mnB, mxB)
							local depth = math.min(ov.X, ov.Y, ov.Z)
							if depth > maxDepth then
								table.insert(
									hits,
									{ t = t, blade = bp.Name, body = rp.Name, depth = depth }
								)
							end
						end
					end
				elseif handle ~= nil and gripPt ~= nil and tipPt ~= nil then
					local samples = 12
					local inside, insidePart = 0, ""
					for i = 1, samples do
						local frac = 0.15 + 0.85 * (i - 1) / (samples - 1)
						local world = handle.CFrame:PointToWorldSpace(
							(gripPt :: Vector3):Lerp(tipPt :: Vector3, frac)
						)
						for _, rp in body do
							local lp = rp.CFrame:PointToObjectSpace(world)
							local half = rp.Size / 2
							if
								math.abs(lp.X) <= half.X
								and math.abs(lp.Y) <= half.Y
								and math.abs(lp.Z) <= half.Z
							then
								inside += 1
								insidePart = rp.Name
								break
							end
						end
					end
					local embedded = (inside / samples)
						* ((tipPt :: Vector3) - (gripPt :: Vector3)).Magnitude
						* 0.85
					if embedded > bodyWorst.studs then
						bodyWorst = { studs = embedded, t = t, part = insidePart }
					end
					if embedded > maxInBody then
						table.insert(
							hits,
							{ t = t, blade = "centerline", body = insidePart, depth = embedded }
						)
					end
				end
				if handle ~= nil and gripPt ~= nil and tipPt ~= nil and #armParts > 0 then
					local samples = 12
					local inside, insidePart = 0, ""
					for i = 1, samples do
						local frac = 0.15 + 0.85 * (i - 1) / (samples - 1)
						local world = handle.CFrame:PointToWorldSpace(
							(gripPt :: Vector3):Lerp(tipPt :: Vector3, frac)
						)
						for _, ap in armParts do
							local lp = ap.CFrame:PointToObjectSpace(world)
							local half = ap.Size / 2
							if
								math.abs(lp.X) <= half.X
								and math.abs(lp.Y) <= half.Y
								and math.abs(lp.Z) <= half.Z
							then
								inside += 1
								insidePart = ap.Name
								break
							end
						end
					end
					local embedded = (inside / samples)
						* ((tipPt :: Vector3) - (gripPt :: Vector3)).Magnitude
						* 0.85
					if embedded > armWorst.studs then
						armWorst = { studs = embedded, t = t, part = insidePart }
					end
				end
			end
		)
		if errMsg ~= nil then
			return unknown(errMsg)
		end
		-- HONESTY RULE: every printed gate sits beside its measurement under its exact arg
		-- name — a stray neighboring mode's threshold reads as the allowance otherwise
		-- (the 2026-07-25 audit misread max_allowed_depth as the arm gate).
		local mag = {
			intersections = hits,
			max_part_aabb_depth = maxDepth,
			blade_in_arm_max_studs = armWorst.studs,
			max_blade_in_arm = maxInArm,
			blade_in_arm_at = armWorst.t,
			blade_in_arm_part = armWorst.part,
			blade_in_body_max_studs = bodyWorst.studs,
			max_blade_in_body = maxInBody,
			blade_in_body_at = bodyWorst.t,
			mode = if bladeDisjoint then "part-aabb" else "centerline (single-part tool)",
		}
		if #hits > 0 then
			return fail(
				#hits
					.. " blade-through-body sample(s), first at t="
					.. string.format("%.2f", hits[1].t),
				mag
			)
		end
		if armWorst.studs > maxInArm then
			return fail(
				string.format("%.2f", armWorst.studs)
					.. " studs of blade centerline INSIDE "
					.. armWorst.part
					.. " at t="
					.. string.format("%.2f", armWorst.t)
					.. " (max "
					.. maxInArm
					.. ")",
				mag
			)
		end
		return pass(mag)
	end,
	20000
)

register(
	"clip_posture_sane",
	"EDIT_OK",
	"Does the BODY stay a body while clip {clip} plays on {rig}? Samples the clip and measures the torso's tilt away from the rig root's own up-axis (rotation-invariant — the fixture may be anchored in any orientation) plus head-above-hips. FAILs past {max_tilt_deg (default 60)} or on any inverted sample (head below hips; allow with {allow_inverted=true} for rolls/flips). Exists because every OTHER clip check is joint-relative: a retarget can fold the character into a heap on the floor and still post healthy sweep/extension/axial numbers (live-caught 2026-07-26 on a generated fencing lunge that passed the thrust bar while lying folded).",
	function(args)
		local rig = if typeof(args.rig) == "Instance"
			then args.rig
			else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
		if rig == nil then
			return unknown("rig not found")
		end
		local root = rig:FindFirstChild("HumanoidRootPart") or (rig :: Model).PrimaryPart
		local torso = rig:FindFirstChild("UpperTorso", true) or rig:FindFirstChild("Torso", true)
		local hips = rig:FindFirstChild("LowerTorso", true) or torso
		local head = rig:FindFirstChild("Head", true)
		if root == nil or torso == nil or head == nil or hips == nil then
			return unknown("rig needs root/torso/hips/head parts")
		end
		local maxTilt = tonumber(args.max_tilt_deg) or 60
		local allowInverted = args.allow_inverted == true
		local worstTilt, worstAt, inverted, invertedAt = 0, 0, 0, -1
		local errMsg = scrubClip(
			rig :: Model,
			tostring(args.clip or "SwordSwing"),
			tonumber(args.samples) or 16,
			function(t)
				local up = (root :: BasePart).CFrame.UpVector
				local tilt = math.deg(
					math.acos(math.clamp((torso :: BasePart).CFrame.UpVector:Dot(up), -1, 1))
				)
				if tilt > worstTilt then
					worstTilt, worstAt = tilt, t
				end
				local spine = (head :: BasePart).Position - (hips :: BasePart).Position
				if spine:Dot(up) <= 0 then
					inverted += 1
					if invertedAt < 0 then
						invertedAt = t
					end
				end
			end
		)
		if errMsg ~= nil then
			return unknown(errMsg)
		end
		local mag = {
			max_torso_tilt_deg = worstTilt,
			max_tilt_deg = maxTilt,
			worst_tilt_at = worstAt,
			inverted_samples = inverted,
			inverted_first_at = if invertedAt >= 0 then invertedAt else nil,
			allow_inverted = allowInverted,
		}
		if inverted > 0 and not allowInverted then
			return fail(
				inverted
					.. " sample(s) with the head BELOW the hips (first at t="
					.. string.format("%.2f", invertedAt)
					.. ") — the character is folded/upside-down, not posed",
				mag
			)
		end
		if worstTilt > maxTilt then
			return fail(
				"torso tilts "
					.. string.format("%.0f", worstTilt)
					.. " deg off the rig's up-axis at t="
					.. string.format("%.2f", worstAt)
					.. " (max "
					.. maxTilt
					.. ")",
				mag
			)
		end
		return pass(mag)
	end,
	20000
)

register(
	"capture_vantage",
	"EDIT_OK",
	"Does each sign-off angle actually SHOW the weapon? For every angle in {angles (default front,right,left)} of the standard orbit framing {rig} (subject-relative via composeYaw), raycasts from the framed camera to 12 declared-centerline samples of tool {tool}; an angle whose visible fraction is under {min_visible_frac (default 0.3)} carries ~no information (a torso-occluded sign-off angle passed silently — audit-caught 2026-07-25) and FAILs, naming its first blocker.",
	function(args)
		local rig = if typeof(args.rig) == "Instance"
			then args.rig
			else select(1, Path.resolve(tostring(args.rig or "game.Workspace.AgentRig")))
		local tool = if typeof(args.tool) == "Instance"
			then args.tool
			else select(1, Path.resolve(tostring(args.tool)))
		if rig == nil or tool == nil then
			return unknown("rig/tool not found")
		end
		local frame = select(1, OracleFrames.read(tool))
		if frame == nil or frame.points.Grip == nil or frame.points.BladeTip == nil then
			return unknown("no Grip/BladeTip points — stamp_frame first")
		end
		local handle = OracleFrames.handleOf(tool)
		if handle == nil then
			return unknown("tool has no Handle part")
		end
		local center, size, terr, facing = CaptureCore.resolveTarget(rig:GetFullName())
		if center == nil or size == nil then
			return unknown("cannot frame the rig: " .. tostring(terr))
		end
		local names = if type(args.angles) == "table"
			then args.angles
			else { "front", "right", "left" }
		local minFrac = tonumber(args.min_visible_frac) or 0.3
		local gripPt, tipPt = frame.points.Grip :: Vector3, frame.points.BladeTip :: Vector3
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {}
		local perAngle = {}
		local failed = {}
		for _, n in names do
			local preset = CaptureCore.PRESETS[string.lower(tostring(n))]
			if preset == nil then
				continue
			end
			local cam = CaptureCore.frameCFrame(
				center :: Vector3,
				size :: Vector3,
				CaptureCore.composeYaw(preset.yaw, facing),
				preset.pitch,
				1
			)
			local samples = 12
			local visible, blocker = 0, ""
			for i = 1, samples do
				local frac = (i - 1) / (samples - 1)
				local pt = handle.CFrame:PointToWorldSpace(gripPt:Lerp(tipPt, frac))
				local dir = pt - cam.Position
				local hit = workspace:Raycast(cam.Position, dir + dir.Unit * 0.1, params)
				-- First surface on the segment: the tool itself (or clear air) = this sample
				-- is visible from the angle; any other part = something occludes it.
				if hit == nil or hit.Instance:IsDescendantOf(tool) then
					visible += 1
				elseif blocker == "" then
					blocker = hit.Instance.Name
				end
			end
			local vf = visible / samples
			table.insert(
				perAngle,
				{ angle = tostring(n), visible_frac = vf, first_blocker = blocker }
			)
			if vf < minFrac then
				table.insert(failed, tostring(n) .. " (" .. string.format("%.2f", vf) .. ")")
			end
		end
		if #perAngle == 0 then
			return unknown("no valid angle names (use front/back/left/right/top/bottom/iso)")
		end
		local mag = { per_angle = perAngle, min_visible_frac = minFrac }
		if #failed > 0 then
			return fail(
				"sign-off angle(s) carry ~no weapon pixels: " .. table.concat(failed, ", "),
				mag
			)
		end
		return pass(mag)
	end
)

-- ---- texture vocabulary (2026-07-25 sprint: the falchion/rapier texture failures, mechanized;
-- the suite's "material/texture quality" blindspot narrows to AESTHETICS only) ----

local AssetService = game:GetService("AssetService")

local function meshPartsUnder(inst: Instance): { MeshPart }
	local out = {}
	if inst:IsA("MeshPart") then
		table.insert(out, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("MeshPart") then
			table.insert(out, d)
		end
	end
	return out
end

-- Open the FINALIZED mesh+texture behind a MeshPart for measurement. Session-backed pre-save
-- parts are UNKNOWN by design (the save_mesh standing rule makes finalized the common case).
-- Both handles MUST be destroyed by the caller (device memory).
local function openEditable(part: MeshPart): (any?, any?, string?)
	if part.MeshId == "" then
		return nil,
			nil,
			"session-backed pre-save mesh (empty MeshId) — save_mesh + confirm_mesh, then re-run"
	end
	local okM, em = pcall(function()
		return (AssetService :: any):CreateEditableMeshAsync(part.MeshContent)
	end)
	if not okM or em == nil then
		return nil,
			nil,
			"CreateEditableMeshAsync failed: "
				.. tostring(em)
				.. " (EditableMesh beta tick? asset moderation?)"
	end
	local okI, img = pcall(function()
		return (AssetService :: any):CreateEditableImageAsync(part.TextureContent)
	end)
	if not okI or img == nil then
		em:Destroy()
		return nil,
			nil,
			"CreateEditableImageAsync failed: "
				.. tostring(img)
				.. " (no TextureContent / beta tick?)"
	end
	return em, img, nil
end

register(
	"texture_applied",
	"EDIT_OK",
	"Every MeshPart under {target} carries a readable texture with NON-TRIVIAL content: TextureContent resolves, image dims sane, and a strided 256-px sample shows real variance (a flat/blank/black apply FAILs — the 'gray weapon' and 'black apply' classes). Magnitudes per part: image_w/h, sample_stddev. UNKNOWN pre-save (empty MeshId).",
	function(args)
		local inst = if typeof(args.target) == "Instance"
			then args.target
			else select(1, Path.resolve(tostring(args.target)))
		if inst == nil then
			return unknown("target not found")
		end
		local parts = meshPartsUnder(inst)
		if #parts == 0 then
			return unknown("no MeshParts under target")
		end
		local mags = {}
		for _, part in parts do
			local em, img, err = openEditable(part)
			if err ~= nil then
				return unknown(part.Name .. ": " .. err)
			end
			local size = img.Size
			local okBuf, buf = pcall(function()
				return img:ReadPixelsBuffer(Vector2.new(0, 0), size)
			end)
			if em then
				em:Destroy()
			end
			if not okBuf then
				img:Destroy()
				return unknown(part.Name .. ": ReadPixelsBuffer failed: " .. tostring(buf))
			end
			img:Destroy()
			local w, h = math.floor(size.X), math.floor(size.Y)
			local n = 256
			local sum, sumsq = 0, 0
			for i = 0, n - 1 do
				local px = math.floor((i * 7919) % w)
				local py = math.floor((math.floor(i * 7919 / w) * 131) % h)
				local off = (py * w + px) * 4
				local lum = (
					buffer.readu8(buf, off)
					+ buffer.readu8(buf, off + 1)
					+ buffer.readu8(buf, off + 2)
				) / 3
				sum += lum
				sumsq += lum * lum
			end
			local mean = sum / n
			local stddev = math.sqrt(math.max(0, sumsq / n - mean * mean))
			table.insert(
				mags,
				{ part = part.Name, image_w = w, image_h = h, sample_stddev = stddev }
			)
			if w < 16 or h < 16 then
				return fail(part.Name .. ": texture is " .. w .. "x" .. h .. " (degenerate)", mags)
			end
			if stddev < (tonumber(args.min_stddev) or 4) then
				return fail(
					part.Name
						.. ": texture sample stddev "
						.. string.format("%.1f", stddev)
						.. " — flat/blank apply",
					mags
				)
			end
		end
		return pass(mags)
	end,
	15000
)

register(
	"texel_stretch",
	"EDIT_OK",
	"On-mesh texel ANISOTROPY for every MeshPart under {target}: per-face singular values of the pixel-space->3D map (UVs scaled by the applied image's dims), sampled over {sample_faces (default 400)} faces. Verdict keys on the MEDIAN (the squared-canvas class multiplies EVERY face, so median ~= uv_aspect: falchion 5.4x, rapier 6.9x — both live-caught by eye first; healthy imports read ~1.0-1.6): FAIL if median > {max_median (default 2.0)}. p95_stretch + grazing_frac (fraction of faces > 4x) ride as magnitudes ONLY — planar-projected meshes carry an honest grazing tail (measured 26x p95 on a healthy longsword; the box-projection escalation owns that, not this verdict). UNKNOWN pre-save or when UV/API unavailable.",
	function(args)
		local inst = if typeof(args.target) == "Instance"
			then args.target
			else select(1, Path.resolve(tostring(args.target)))
		if inst == nil then
			return unknown("target not found")
		end
		local parts = meshPartsUnder(inst)
		if #parts == 0 then
			return unknown("no MeshParts under target")
		end
		local mags = {}
		for _, part in parts do
			local em, img, err = openEditable(part)
			if err ~= nil then
				return unknown(part.Name .. ": " .. err)
			end
			local size = img.Size
			img:Destroy()
			local w, h = size.X, size.Y
			local ratios = {}
			local okWalk, walkErr = pcall(function()
				local faces = em:GetFaces()
				local total = #faces
				local want = math.min(total, tonumber(args.sample_faces) or 400)
				local step = math.max(1, math.floor(total / want))
				for fi = 1, total, step do
					local face = faces[fi]
					local vids = em:GetFaceVertices(face)
					local uids = em:GetFaceUVs(face)
					if #vids == 3 and #uids == 3 then
						local p1 = em:GetPosition(vids[1])
						local p2 = em:GetPosition(vids[2])
						local p3 = em:GetPosition(vids[3])
						local q1 = em:GetUV(uids[1])
						local q2 = em:GetUV(uids[2])
						local q3 = em:GetUV(uids[3])
						local e1, e2 = p2 - p1, p3 - p1
						local u1 = Vector2.new((q2.X - q1.X) * w, (q2.Y - q1.Y) * h)
						local u2 = Vector2.new((q3.X - q1.X) * w, (q3.Y - q1.Y) * h)
						local det = u1.X * u2.Y - u1.Y * u2.X
						if math.abs(det) > 1e-9 then
							-- J = [e1 e2] * inv([u1 u2]) maps px -> 3D; Gram G = J^T J (2x2)
							local a, b = u2.Y / det, -u2.X / det
							local c, d = -u1.Y / det, u1.X / det
							local j1 = e1 * a + e2 * c -- d3D/dpx_x
							local j2 = e1 * b + e2 * d -- d3D/dpx_y
							local g11, g12, g22 = j1:Dot(j1), j1:Dot(j2), j2:Dot(j2)
							local tr, dt = g11 + g22, g11 * g22 - g12 * g12
							local disc = math.sqrt(math.max(0, tr * tr / 4 - dt))
							local l1, l2 = tr / 2 + disc, tr / 2 - disc
							if l2 > 1e-18 then
								table.insert(ratios, math.sqrt(l1 / l2))
							end
						end
					end
				end
			end)
			em:Destroy()
			if not okWalk then
				return unknown(part.Name .. ": EditableMesh UV walk failed: " .. tostring(walkErr))
			end
			if #ratios < 8 then
				return unknown(part.Name .. ": too few measurable UV faces (" .. #ratios .. ")")
			end
			table.sort(ratios)
			local median = ratios[math.floor(#ratios / 2) + 1]
			local p95 = ratios[math.max(1, math.floor(#ratios * 0.95))]
			local grazing = 0
			for _, r in ratios do
				if r > 4 then
					grazing += 1
				end
			end
			table.insert(mags, {
				part = part.Name,
				faces_measured = #ratios,
				median_stretch = median,
				p95_stretch = p95,
				grazing_frac = grazing / #ratios,
			})
			if median > (tonumber(args.max_median) or 2.0) then
				return fail(
					part.Name
						.. ": MEDIAN texel anisotropy "
						.. string.format("%.2f", median)
						.. "x (max "
						.. (tonumber(args.max_median) or 2.0)
						.. ") — the squared-canvas / stretched-atlas class",
					mags
				)
			end
		end
		return pass(mags)
	end,
	20000
)

register(
	"extents_profile",
	"EDIT_OK",
	"GIGO slab gate for {target} (melee-weapon calibration): sorted OBJECT-SPACE extents long>=mid>=thin (world AABBs cube-ify a diagonally-HELD tool — live-caught mid/long 0.90 on the equipped longsword; the union is taken in the FIRST part's local frame, exact for single-part tools, pose-independent); FAIL the photo-card-slab signature mid/long > {max_mid_frac (default 0.55)} (a backdrop voxelized into a card — birefnet/threshold bg failure) and the degenerate wire mid/long < {min_mid_frac (default 0.02)}. Shipped calibration: longsword .24, falchion .37, rapier .29. Raw magnitudes always reported so the band can harden.",
	function(args)
		local parts, perr = resolveParts(args.target)
		if parts == nil or #parts == 0 then
			return unknown(perr or "target not found / no parts")
		end
		-- Union every part's corners in the FIRST part's OBJECT space: pose-independent.
		local ref = parts[1].CFrame
		local big = math.huge
		local mnx, mny, mnz, mxx, mxy, mxz = big, big, big, -big, -big, -big
		for _, p in parts do
			local rel = ref:ToObjectSpace(p.CFrame)
			local half = p.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local c = rel:PointToWorldSpace(
							Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
						)
						mnx, mny, mnz = math.min(mnx, c.X), math.min(mny, c.Y), math.min(mnz, c.Z)
						mxx, mxy, mxz = math.max(mxx, c.X), math.max(mxy, c.Y), math.max(mxz, c.Z)
					end
				end
			end
		end
		local e = { mxx - mnx, mxy - mny, mxz - mnz }
		table.sort(e, function(a, b)
			return a > b
		end)
		local long, mid, thin = e[1], e[2], e[3]
		local mag = {
			long_studs = long,
			mid_studs = mid,
			thin_studs = thin,
			mid_over_long = mid / math.max(long, 1e-9),
			thin_over_long = thin / math.max(long, 1e-9),
		}
		local maxMid = tonumber(args.max_mid_frac) or 0.55
		local minMid = tonumber(args.min_mid_frac) or 0.02
		if mag.mid_over_long > maxMid then
			return fail(
				string.format(
					"mid/long %.2f exceeds %.2f — slab signature (bg voxelized into a card?)",
					mag.mid_over_long,
					maxMid
				),
				mag
			)
		end
		if mag.mid_over_long < minMid then
			return fail(
				string.format(
					"mid/long %.3f below %.3f — degenerate wire",
					mag.mid_over_long,
					minMid
				),
				mag
			)
		end
		return pass(mag)
	end
)

-- ---- declaration stubs (phase 2+): registered so suites/manifests can reference them;
-- each returns UNKNOWN until implemented. PLAY_ONLY stubs need a runtime twin. ----
local function declStub(name: string, validity: string)
	register(name, validity, "Declared; implemented in phase 2+.", function(_args)
		return unknown("declared; implemented in phase 2+")
	end)
end
declStub("track_priority_audit", "PLAY_ONLY")
declStub("impulse_effective", "PLAY_ONLY")
declStub("load_scale_probe", "PLAY_ONLY")
declStub("rig_uniform", "EDIT_OK")
declStub("clip_joint_mask", "EDIT_OK")

-- ---- runtime twins (SP2d follow-up) ----
-- twinOf maps an EDIT_MISLEADS check to the PLAY_ONLY twin that discharges its provisional pass.
-- Twin IMPLEMENTATIONS live in the injected run-mode server (PlayBridge SERVER_SRC, `play oracle`
-- verb) because the edit DM is frozen while Execute*ModeAsync runs — the plugin cannot execute
-- them itself. Registered here as pointers so oracle_check answers with the run-mode recipe.
M.twinOf = {
	anchored_ok = "anchored_weld_census",
	clip_arc_of = "played_arc_of",
} :: { [string]: string }

local RUN_TWIN_HINT = " Runs INSIDE run mode: playtest_start {mode:'run'}, then shell `play oracle "
	.. '\'{"check":"<name>","args":{"target":"..."}}\'` — feed the returned JSON back to oracle_suite as twin_results[].'
register(
	"anchored_weld_census",
	"PLAY_ONLY",
	"Runtime twin of anchored_ok: anchored/Motor6D/Weld census for {target} under LIVE physics."
		.. RUN_TWIN_HINT,
	function(_args)
		return unknown("PLAY_ONLY twin — execute via `play oracle` in run mode, not in edit")
	end
)
register(
	"stable_over",
	"PLAY_ONLY",
	"{target} holds position under live physics for {seconds} (default 2, cap 8); FAIL when drift > {max_drift} studs (default 0.5)."
		.. RUN_TWIN_HINT,
	function(_args)
		return unknown("PLAY_ONLY twin — execute via `play oracle` in run mode, not in edit")
	end
)
register(
	"played_arc_of",
	"PLAY_ONLY",
	"Runtime twin of clip_arc_of: plays {clip} on {rig}'s REAL Animator under run-mode stepping and sweeps {part (default Handle)} — max angle between root->point unit vectors per heartbeat (traces Semantic_BladeTip when the part carries one). PASS if sweep >= {min_sweep (default 60, matching clip_arc_of)}. Magnitudes: sweep_deg, samples, duration_ms."
		.. RUN_TWIN_HINT,
	function(_args)
		return unknown("PLAY_ONLY twin — execute via `play oracle` in run mode, not in edit")
	end
)
register(
	"offhand_reach",
	"PLAY_ONLY",
	"Does the AgentOffHandIK stamped by grip_tool {offhand:true} SOLVE under live run-mode stepping? Samples (LeftHand - IK Target).Magnitude every heartbeat for {seconds (default 2)} on {rig}. PASS iff dist_min < 1.5; FAIL quotes dist_start/dist_min/dist_end (missing IKControl is a measured FAIL). Answers the SP2c open question — either verdict is valuable."
		.. RUN_TWIN_HINT,
	function(_args)
		return unknown("PLAY_ONLY twin — execute via `play oracle` in run mode, not in edit")
	end
)

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
			reason = "unknown check: " .. tostring(name) .. " (available: " .. table.concat(
				names,
				", "
			) .. ")",
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
