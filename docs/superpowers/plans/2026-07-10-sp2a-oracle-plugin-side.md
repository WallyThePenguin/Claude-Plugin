# SP2 Plan A — Oracle Plugin Side (frames, checks, four tools, selftest)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The plugin-side Roblox Oracle: semantic frames + a check registry + four bridge tools (`oracle_check`, `oracle_suite`, `read_frame`, `stamp_frame`) + an in-place selftest — independently testable over the bridge. Factory coupling is Plan B.

**Architecture:** Three new Luau modules under `src/Tools/` following the house Descriptor pattern (see `src/Tools/Place.luau`): `OracleFrames.luau` (family schemas; stamp/read via Attachments + `SemanticFrame` JSON attribute + CollectionService `Semantic_*` tags), `OracleChecks.luau` (registry of deterministic checks returning `{verdict, magnitudes, validity, cost_ms}`), `Oracle.luau` (the four tool descriptors + suite runner + blindspot manifest). `ToolFactory.luau` gains frame-aware grip alignment. Spec: `docs/superpowers/specs/2026-07-10-sp2-roblox-oracle-design.md`.

**Tech Stack:** Luau (plugin, edit mode), existing helpers: `Path.resolve`, `ToolFactory.equip/applyGrip` (AgentEditGrip weld: C0=RightGripAttachment.CFrame, C1=Tool.Grip), `AnimationClip` (AnimSaves KeyframeSequences, `register(ks)`), the `capture_animation` scrub pattern (save Motor6D transforms → Animator `TimePosition` + `StepAnimations(0)` → restore).

**Verification constraint:** Luau cannot run outside Studio, and the forever soak may own the bridge while Tasks 1–5 are implemented. Therefore Tasks 1–5 are code+static-review only (careful transcription, reviewer scrutiny); Task 6 is the batched LIVE verification (hot-reload + `__selftest` + probes) once the bridge is free. Do not claim live verification before Task 6.

**Conventions:** never `git add -A`; commit prefixes `feat(tools)` / `feat(plugin)`. Descriptor type: `{name, description, inputSchema, destructive, run(input, context) -> (Content, boolean)}` where Content = string | blocks array; return `(json, false)` on success, `(json, true)` on error; `inputSchema` is camelCase in Luau (init.luau maps to `input_schema`).

---

### Task 1: `OracleFrames.luau` — schemas, stamp, read

**Files:** Create: `src/Tools/OracleFrames.luau`

- [ ] **Step 1: Write the module**

```lua
--!strict
-- OracleFrames — semantic frames: declare asset semantics at BUILD time (SP2 spec §2.6).
-- Points ride as Attachments on the Handle (Semantic_<Name>); directions ride the
-- SemanticFrame JSON attribute as Handle-local unit vectors; part roles ride
-- CollectionService tags (Semantic_<role>). Never infer at verify time what the
-- builder could declare at build time.
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local Path = require(script.Parent.Path)

local M = {}

M.TAG_PREFIX = "Semantic_"
M.ATTR = "SemanticFrame"

M.SCHEMAS = {
	["melee-weapon"] = {
		points = { "Grip", "BladeTip" },
		dirs = { "blade_dir", "edge_dir" },
		roles = { required = { "hilt", "blade" }, optional = { "guard", "pommel" } },
	},
}

function M.handleOf(inst: Instance): BasePart?
	if inst:IsA("Tool") then
		local h = inst:FindFirstChild("Handle")
		return if h ~= nil and h:IsA("BasePart") then h else nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function vec(t: any): Vector3
	return Vector3.new(tonumber(t.x) or 0, tonumber(t.y) or 0, tonumber(t.z) or 0)
end

-- stamp(target, frame) -> (summary, ok). frame = { family, points = {Grip={x,y,z}, ...} (Handle-local),
-- dirs = {blade_dir={x,y,z}, ...} (Handle-local, normalized here), roles = {hilt={"partNameOrPath",...}, ...} }
function M.stamp(target: Instance, frame: any): (any, boolean)
	local schema = M.SCHEMAS[tostring(frame.family)]
	if schema == nil then
		return { error = "unknown family: " .. tostring(frame.family) .. " (known: melee-weapon)" }, false
	end
	local handle = M.handleOf(target)
	if handle == nil then
		return { error = "target has no BasePart handle" }, false
	end
	local stamped, errors = {}, {}
	for _, name in schema.points do
		local p = if type(frame.points) == "table" then frame.points[name] else nil
		if type(p) == "table" then
			local att = handle:FindFirstChild(M.TAG_PREFIX .. name)
			if att == nil or not att:IsA("Attachment") then
				att = Instance.new("Attachment")
				att.Name = M.TAG_PREFIX .. name
				att.Parent = handle
			end
			(att :: Attachment).Position = vec(p)
			table.insert(stamped, "point:" .. name)
		end
	end
	local dirs = {}
	for _, name in schema.dirs do
		local d = if type(frame.dirs) == "table" then frame.dirs[name] else nil
		if type(d) == "table" then
			local v = vec(d)
			if v.Magnitude < 1e-4 then
				table.insert(errors, "dir " .. name .. " is a zero vector")
			else
				dirs[name] = { x = v.Unit.X, y = v.Unit.Y, z = v.Unit.Z }
				table.insert(stamped, "dir:" .. name)
			end
		end
	end
	if type(frame.roles) == "table" then
		for role, entries in frame.roles :: { [string]: any } do
			local known = table.find(schema.roles.required, role) or table.find(schema.roles.optional, role)
			if known == nil then
				table.insert(errors, "unknown role: " .. tostring(role))
			elseif type(entries) == "table" then
				for _, entry in entries do
					local inst = select(1, Path.resolve(tostring(entry)))
					if inst == nil then
						inst = target:FindFirstChild(tostring(entry), true)
					end
					if inst ~= nil and inst:IsA("BasePart") then
						CollectionService:AddTag(inst, M.TAG_PREFIX .. role)
						table.insert(stamped, "role:" .. role .. "/" .. inst.Name)
					else
						table.insert(errors, "role " .. role .. ": part not found: " .. tostring(entry))
					end
				end
			end
		end
	end
	handle:SetAttribute(M.ATTR, HttpService:JSONEncode({ family = frame.family, dirs = dirs }))
	return { stamped = stamped, errors = errors }, #errors == 0
end

-- read(target) -> (frame, err?). frame = { family, points = {name -> Vector3 (Handle-local)},
-- dirs = {name -> Vector3 (Handle-local unit)}, roleParts = {role -> {BasePart}}, missing = {string} }
function M.read(target: Instance): (any, string?)
	local handle = M.handleOf(target)
	if handle == nil then
		return nil, "target has no BasePart handle"
	end
	local decoded: any = nil
	local raw = handle:GetAttribute(M.ATTR)
	if type(raw) == "string" then
		local ok, d = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok then
			decoded = d
		end
	end
	local family = if decoded ~= nil then decoded.family else nil
	local schema = if family ~= nil then M.SCHEMAS[family] else nil
	local frame = { family = family, points = {}, dirs = {}, roleParts = {}, missing = {} }
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") and child.Name:sub(1, #M.TAG_PREFIX) == M.TAG_PREFIX then
			frame.points[child.Name:sub(#M.TAG_PREFIX + 1)] = child.Position
		end
	end
	if decoded ~= nil and type(decoded.dirs) == "table" then
		for name, d in decoded.dirs :: { [string]: any } do
			frame.dirs[name] = vec(d)
		end
	end
	local container: Instance = if handle.Parent ~= nil and handle.Parent:IsA("Tool") then handle.Parent else handle
	local parts: { Instance } = if container:IsA("Tool") then container:GetDescendants() else { handle :: Instance }
	for _, part in parts do
		if part:IsA("BasePart") then
			for _, tag in CollectionService:GetTags(part) do
				if tag:sub(1, #M.TAG_PREFIX) == M.TAG_PREFIX then
					local role = tag:sub(#M.TAG_PREFIX + 1)
					if frame.roleParts[role] == nil then
						frame.roleParts[role] = {}
					end
					table.insert(frame.roleParts[role], part)
				end
			end
		end
	end
	if schema ~= nil then
		for _, p in schema.points do
			if frame.points[p] == nil then
				table.insert(frame.missing, "point:" .. p)
			end
		end
		for _, d in schema.dirs do
			if frame.dirs[d] == nil then
				table.insert(frame.missing, "dir:" .. d)
			end
		end
		for _, r in schema.roles.required do
			if frame.roleParts[r] == nil then
				table.insert(frame.missing, "role:" .. r)
			end
		end
	else
		table.insert(frame.missing, "frame attribute (family) — stamp_frame has not run")
	end
	return frame, nil
end

return M
```

- [ ] **Step 2: Commit**

```bash
git add src/Tools/OracleFrames.luau
git commit -m "feat(tools): OracleFrames — semantic frame schemas, stamp, read (SP2a T1)"
```

---

### Task 2: `OracleChecks.luau` — registry + geometry + frame + grip checks

**Files:** Create: `src/Tools/OracleChecks.luau`

- [ ] **Step 1: Write the module** (registry infrastructure + this task's checks; Task 3 appends the rig/clip checks into the same registry table)

```lua
--!strict
-- OracleChecks — the check registry: named deterministic measurements over the live
-- DataModel. Results are ALWAYS {verdict = PASS|FAIL|UNKNOWN, reason?, magnitudes = {...},
-- validity, context, cost_ms} — raw magnitudes ride every result (never bare booleans);
-- UNKNOWN never satisfies a suite (SP2 spec §2.1-2.5). Checks never throw: internal
-- errors become UNKNOWN(internal).
local CollectionService = game:GetService("CollectionService")

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
		return collectParts(pathOrInst), nil
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

local function register(name: string, validity: string, description: string, fn: (any) -> any)
	M.checks[name] = { validity = validity, context = "edit", description = description, fn = fn }
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
		ref = Vector3.new(tonumber(args.against.x) or 0, tonumber(args.against.y) or 0, tonumber(args.against.z) or 0).Unit
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
		local lp = handle.CFrame:PointToObjectSpace(p.Position)
		local half = p.Size.Magnitude / 2
		local lo, hi = lp - Vector3.one * half, lp + Vector3.one * half
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

-- run(name, args) -> result (adds validity/context/cost_ms; never throws)
function M.run(name: string, args: any): any
	local entry = M.checks[name]
	if entry == nil then
		local names = {}
		for n in M.checks do
			table.insert(names, n)
		end
		table.sort(names)
		return { verdict = "UNKNOWN", reason = "unknown check: " .. tostring(name) .. " (available: " .. table.concat(names, ", ") .. ")", magnitudes = {} }
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
	return result
end

return M
```

- [ ] **Step 2: Commit**

```bash
git add src/Tools/OracleChecks.luau
git commit -m "feat(tools): OracleChecks — registry + geometry/frame/grip checks with raw magnitudes (SP2a T2)"
```

---

### Task 3: rig + clip checks (append to `OracleChecks.luau`)

**Files:** Modify: `src/Tools/OracleChecks.luau` (insert the block below immediately BEFORE the `-- run(name, args)` comment)

- [ ] **Step 1: Append the checks**

```lua
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
	local id = AnimationClip.register(ks)
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
			visit(t)
		end
	end
	track:Stop(0)
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
		for j = i + 1, #positions do
			local a = (positions[i] - rootPos).Unit
			local b = (positions[j] - rootPos).Unit
			sweep = math.max(sweep, math.deg(math.acos(math.clamp(a:Dot(b), -1, 1))))
		end
	end
	local minSweep = tonumber(args.min_sweep) or 60
	local mag = { sweep_deg = sweep, path_studs = pathLen, max_reach_studs = maxReach, samples = #positions }
	return if sweep >= minSweep then pass(mag) else fail("swing sweeps only " .. string.format("%.0f", sweep) .. " deg (min " .. minSweep .. ")", mag)
end)

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
end)
```

- [ ] **Step 2: Commit**

```bash
git add src/Tools/OracleChecks.luau
git commit -m "feat(tools): oracle rig + kinematic clip checks — census, channels, arc, self-intersect (SP2a T3)"
```

---

### Task 4: `Oracle.luau` — the four tools, suite, manifest, selftest + registration

**Files:** Create: `src/Tools/Oracle.luau`; Modify: `src/Tools/init.luau` (require + append loop)

- [ ] **Step 1: Write the module**

```lua
--!strict
-- Oracle — the four oracle tools (SP2 spec §3): oracle_check, oracle_suite, read_frame,
-- stamp_frame. Suites emit a blindspot manifest: all-green must be unreadable as "done".
local HttpService = game:GetService("HttpService")

local Path = require(script.Parent.Path)
local OracleChecks = require(script.Parent.OracleChecks)
local OracleFrames = require(script.Parent.OracleFrames)

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local Oracle = {}

local function encode(payload: any): string
	local ok, s = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	return if ok then s else '{"ok":false,"error":"encode failed"}'
end

-- Per-family suites: ordered checks (args templated on {target, rig}) + the NOT-asserted list.
local SUITES = {
	["melee-weapon"] = {
		checks = function(target: string, rig: string?)
			return {
				{ check = "frame_consistent", args = { target = target } },
				{ check = "anchored_ok", args = { target = target } },
				{ check = "scale_ratio", args = { target = target, expected = 4.5, tolerance_frac = 0.6 } },
				{ check = "grip_sane", args = { tool = target, rig = rig } },
				{ check = "joint_census", args = { rig = rig } },
				{ check = "clip_arc_of", args = { rig = rig, tool = target } },
				{ check = "clip_self_intersect", args = { rig = rig, tool = target } },
			}
		end,
		notAsserted = {
			"material/texture quality", "silhouette aesthetics vs references", "color palette",
			"swing FEEL (weight/anticipation)", "damage numbers at runtime (playtest twin)",
			"animation under the runtime Animator with locomotion blending (PLAY_ONLY twin)",
		},
	},
}

local function runSuite(family: string, target: string, rig: string?): any
	local suite = SUITES[family]
	if suite == nil then
		local names = {}
		for n in SUITES do
			table.insert(names, n)
		end
		return { ok = false, error = "unknown suite family: " .. family .. " (available: " .. table.concat(names, ", ") .. ")" }
	end
	local results = {}
	local counts = { PASS = 0, FAIL = 0, UNKNOWN = 0 }
	for _, spec in suite.checks(target, rig) do
		local r = OracleChecks.run(spec.check, spec.args)
		table.insert(results, r)
		counts[r.verdict] = (counts[r.verdict] or 0) + 1
	end
	local frame = nil
	local inst = select(1, Path.resolve(target))
	if inst ~= nil then
		frame = select(1, OracleFrames.read(inst))
	end
	return {
		ok = true,
		family = family,
		counts = counts,
		results = results,
		frameMissing = if frame ~= nil then frame.missing else { "target unresolved" },
		blindspots = suite.notAsserted,
		note = "UNKNOWN never satisfies; blindspots list what was NOT asserted — a green suite is not 'done'.",
	}
end

-- __selftest: builds known-good/known-bad fixtures under workspace.OracleSelfTest,
-- asserts expected verdicts, cleans up. Geometry + frame checks only (grip/clip need a
-- rig and are exercised by the acceptance demo).
local function selftest(): any
	local old = workspace:FindFirstChild("OracleSelfTest")
	if old ~= nil then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "OracleSelfTest"
	folder.Parent = workspace
	local function box(name: string, size: Vector3, cf: CFrame): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Anchored = true
		p.Parent = folder
		return p
	end
	local origin = CFrame.new(0, 100, 0)
	-- a toy sword: grip cylinder at origin, blade box above it along +Y
	local grip = box("GripPart", Vector3.new(0.4, 1.2, 0.4), origin)
	local blade = box("BladePart", Vector3.new(0.4, 4, 0.15), origin * CFrame.new(0, 2.6, 0))
	local results = {}
	local function expect(name: string, verdict: string, r: any)
		table.insert(results, { name = name, expected = verdict, got = r.verdict, ok = r.verdict == verdict, reason = r.reason, magnitudes = r.magnitudes })
	end
	expect("boxes intersect (overlapping)", "PASS", OracleChecks.run("intersects", { a = grip, b = box("Overlap", Vector3.new(1, 1, 1), origin) }))
	expect("gap within limit", "PASS", OracleChecks.run("gap_between", { a = grip, b = blade, max_gap = 1.5 }))
	expect("far boxes fail gap", "FAIL", OracleChecks.run("gap_between", { a = grip, b = box("Far", Vector3.new(1, 1, 1), origin * CFrame.new(20, 0, 0)), max_gap = 0.5 }))
	-- frame roundtrip on the toy sword (grip as the "handle": stamp on a Model wrapper)
	local model = Instance.new("Model")
	model.Name = "ToySword"
	model.Parent = folder
	grip.Parent = model
	blade.Parent = model
	model.PrimaryPart = grip
	local _, stampOk = OracleFrames.stamp(model, {
		family = "melee-weapon",
		points = { Grip = { x = 0, y = 0, z = 0 }, BladeTip = { x = 0, y = 4.6, z = 0 } },
		dirs = { blade_dir = { x = 0, y = 1, z = 0 }, edge_dir = { x = 0, y = 0, z = 1 } },
		roles = { hilt = { "GripPart" }, blade = { "BladePart" } },
	})
	table.insert(results, { name = "stamp accepts a valid frame", expected = true, got = stampOk, ok = stampOk == true })
	expect("consistent frame passes", "PASS", OracleChecks.run("frame_consistent", { target = model }))
	-- sabotage: declare blade_dir 90 degrees off -> the anti-lie layer must FAIL it
	OracleFrames.stamp(model, { family = "melee-weapon", dirs = { blade_dir = { x = 1, y = 0, z = 0 } } })
	expect("lying blade_dir is caught", "FAIL", OracleChecks.run("frame_consistent", { target = model }))
	expect("unknown check reports UNKNOWN", "UNKNOWN", OracleChecks.run("no_such_check", {}))
	folder:Destroy()
	local failures = 0
	for _, r in results do
		if not r.ok then
			failures += 1
		end
	end
	return { ok = failures == 0, failures = failures, results = results }
end

Oracle.descriptors = {
	{
		name = "oracle_check",
		description = "Run ONE named oracle check (deterministic measurement, ~50-token result with raw magnitudes). "
			.. "Checks: intersects{a,b}, penetration_depth{a,b,max_depth}, gap_between{a,b,max_gap}, "
			.. "alignment{target,dir,against,max_deg,length}, scale_ratio{target,expected,tolerance_frac}, "
			.. "anchored_ok{target}, frame_consistent{target}, grip_sane{tool,rig}, joint_census{rig}, "
			.. "rig_channel_check{rig,clip}, clip_arc_of{rig,tool,clip,samples,min_sweep}, "
			.. "clip_self_intersect{rig,tool,clip,samples,max_depth}, __selftest{}. "
			.. "Verdicts: PASS|FAIL|UNKNOWN (UNKNOWN never counts as pass). Prefer these over captures for anything measurable.",
		inputSchema = {
			type = "object",
			properties = {
				check = { type = "string", description = "check name from the registry" },
				args = { type = "object", description = "check arguments (paths as dot-paths, e.g. game.StarterPack.Sword)" },
			},
			required = { "check" },
		},
		destructive = false,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			if tostring(args.check) == "__selftest" then
				local r = selftest()
				return encode(r), not r.ok
			end
			local r = OracleChecks.run(tostring(args.check), args.args)
			return encode(r), r.verdict == "UNKNOWN" and r.reason ~= nil and r.reason:find("unknown check") ~= nil
		end,
	},
	{
		name = "oracle_suite",
		description = "Run the full oracle suite for a family against a target (and optional rig). Returns per-check "
			.. "verdicts + magnitudes, counts, the frame's missing fields, and the BLINDSPOT MANIFEST (what was NOT "
			.. "asserted — those items still need captures/rubric judgment). Families: melee-weapon.",
		inputSchema = {
			type = "object",
			properties = {
				family = { type = "string" },
				target = { type = "string", description = "dot-path to the Tool/Model under test" },
				rig = { type = "string", description = "optional dot-path to the rig (default workspace.AgentRig)" },
			},
			required = { "family", "target" },
		},
		destructive = false,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			local r = runSuite(tostring(args.family), tostring(args.target), if args.rig ~= nil then tostring(args.rig) else nil)
			return encode(r), r.ok ~= true
		end,
	},
	{
		name = "read_frame",
		description = "Read a target's semantic frame: declared points/dirs/part-roles and which schema fields are missing.",
		inputSchema = {
			type = "object",
			properties = { target = { type = "string" } },
			required = { "target" },
		},
		destructive = false,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			local inst, err = Path.resolve(tostring(args.target))
			if inst == nil then
				return encode({ ok = false, error = err or "not found" }), true
			end
			local frame, ferr = OracleFrames.read(inst)
			if frame == nil then
				return encode({ ok = false, error = ferr }), true
			end
			local points = {}
			for name, v in frame.points :: { [string]: Vector3 } do
				points[name] = { x = v.X, y = v.Y, z = v.Z }
			end
			local dirs = {}
			for name, v in frame.dirs :: { [string]: Vector3 } do
				dirs[name] = { x = v.X, y = v.Y, z = v.Z }
			end
			local roles = {}
			for role, parts in frame.roleParts :: { [string]: { BasePart } } do
				roles[role] = {}
				for _, p in parts do
					table.insert(roles[role], p.Name)
				end
			end
			return encode({ ok = true, family = frame.family, points = points, dirs = dirs, roles = roles, missing = frame.missing }), false
		end,
	},
	{
		name = "stamp_frame",
		description = "Declare a target's semantic frame at BUILD time (points are Handle-local {x,y,z}; dirs are "
			.. "Handle-local unit vectors; roles list part names or dot-paths). Schema for melee-weapon: points Grip+"
			.. "BladeTip, dirs blade_dir+edge_dir, roles hilt+blade (optional guard/pommel). Stamp BEFORE make_tool "
			.. "previews; grip_tool aligns to Semantic_Grip when present. Unknown fields are rejected.",
		inputSchema = {
			type = "object",
			properties = {
				target = { type = "string" },
				frame = { type = "object", description = "{family, points, dirs, roles}" },
			},
			required = { "target", "frame" },
		},
		destructive = true,
		run = function(input, _context)
			local args = if type(input) == "table" then input else {}
			local inst, err = Path.resolve(tostring(args.target))
			if inst == nil then
				return encode({ ok = false, error = err or "not found" }), true
			end
			local summary, ok = OracleFrames.stamp(inst, if type(args.frame) == "table" then args.frame else {})
			summary.ok = ok
			return encode(summary), not ok
		end,
	},
}

return Oracle
```

- [ ] **Step 2: Register in `src/Tools/init.luau`** — add near the other requires (around line 35):

```lua
local OracleTool = require(script.Oracle)
```

and add the append loop next to the other module loops (around lines 138-197):

```lua
for _, descriptor in OracleTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

- [ ] **Step 3: Commit**

```bash
git add src/Tools/Oracle.luau src/Tools/init.luau
git commit -m "feat(tools): oracle_check/oracle_suite/read_frame/stamp_frame + selftest + registration (SP2a T4)"
```

---

### Task 5: frame-aware grip in `ToolFactory.luau` + `make_tool` auto-stamp

**Files:** Modify: `src/ToolFactory.luau`; Modify: `src/Tools/Item.luau` (grip_tool description note)

- [ ] **Step 1: Add frame alignment to ToolFactory** — insert after `applyGrip` (ToolFactory.luau:171):

```lua
-- Frame-aware grip (SP2): when the Handle carries a Semantic_Grip attachment (+ blade_dir
-- in the SemanticFrame attribute), compute the Grip CFrame that aligns the declared grip
-- point to the palm with blade_dir along the hand's up axis — mis-grips become impossible
-- rather than merely detectable. Returns nil when the frame is absent (caller falls back
-- to offset/rot mode).
function ToolFactory.gripFromFrame(tool: Tool): CFrame?
	local handle = tool:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		return nil
	end
	local att = handle:FindFirstChild("Semantic_Grip")
	if att == nil or not att:IsA("Attachment") then
		return nil
	end
	local bladeDir = Vector3.yAxis
	local raw = handle:GetAttribute("SemanticFrame")
	if type(raw) == "string" then
		local ok, decoded = pcall(function()
			return game:GetService("HttpService"):JSONDecode(raw)
		end)
		if ok and type(decoded) == "table" and type(decoded.dirs) == "table" and type(decoded.dirs.blade_dir) == "table" then
			local d = decoded.dirs.blade_dir
			local v = Vector3.new(tonumber(d.x) or 0, tonumber(d.y) or 0, tonumber(d.z) or 0)
			if v.Magnitude > 1e-4 then
				bladeDir = v.Unit
			end
		end
	end
	-- Build the handle-space frame at the grip point with blade_dir as UP; Grip (weld C1) is
	-- the handle-relative CFrame whose inverse places the handle in the hand: hand-up == blade up.
	local up = bladeDir
	local fwd = if math.abs(up:Dot(Vector3.zAxis)) < 0.9 then up:Cross(Vector3.zAxis).Unit else up:Cross(Vector3.xAxis).Unit
	local right = up:Cross(fwd).Unit
	fwd = right:Cross(up).Unit
	return CFrame.fromMatrix(att.Position, right, up, -fwd)
end
```

- [ ] **Step 2: Consume it in Item.luau's grip_tool** — in `runGripTool` (Item.luau, around line 112), BEFORE the offset/rot conversion, add:

```lua
	local frameGrip = if args.offset == nil and args.rot == nil then ToolFactory.gripFromFrame(tool) else nil
	local grip = if frameGrip ~= nil then frameGrip else ToolFactory.gripCFrame(offset, rot)
```

(adjust the existing local so `grip` feeds the same `applyGrip` call; when `frameGrip` is used, append `" (aligned to Semantic_Grip frame)"` to the tool's result text). Also extend the `grip_tool` descriptor description with: `"When the tool carries a Semantic_Grip frame (stamp_frame) and no offset/rot is given, the grip AUTO-ALIGNS to the declared frame."`

- [ ] **Step 3: make_tool auto-stamp candidate** — in `ToolFactory.make` (after `handle.Name = "Handle"`), add:

```lua
	if handle:FindFirstChild("Semantic_Grip") == nil then
		local att = Instance.new("Attachment")
		att.Name = "Semantic_Grip"
		att.Position = Vector3.zero -- candidate: handle center; stamp_frame refines
		att.Parent = handle
	end
```

and extend `make_tool`'s descriptor description with: `"Stamps a candidate Semantic_Grip at the Handle center if none exists — run stamp_frame for the full semantic frame (family schema) before previewing."`

- [ ] **Step 4: Commit**

```bash
git add src/ToolFactory.luau src/Tools/Item.luau
git commit -m "feat(plugin): frame-aware grip alignment + make_tool Semantic_Grip candidate (SP2a T5)"
```

---

### Task 6: LIVE verification battery (needs Studio + free bridge)

**Files:** none (runtime verification; fixes-if-found get their own commits)

- [ ] **Step 1: Confirm the bridge is free** (`curl -s http://127.0.0.1:8389/forever/status` shows state != running), then hot-reload: `.\scripts\studio-agent.ps1 reload` → `reload ok`.
- [ ] **Step 2: Selftest over the bridge:** `.\scripts\studio-agent.ps1 tool oracle_check '{"check": "__selftest"}'` → expect `ok=True` and `"failures":0` with the "lying blade_dir is caught" row FAIL→ok=true. Any failure: diagnose in the module, fix minimally, commit `fix(tools): ...`, re-run.
- [ ] **Step 3: Frame roundtrip on a real Tool:** spawn a rig (`tool spawn_rig '{}'`), build a quick 2-part sword via `luau`, `make_tool`, `stamp_frame`, `read_frame` → missing list shrinks to []; `oracle_suite '{"family":"melee-weapon","target":"game.Workspace.<tool path>","rig":"game.Workspace.AgentRig"}'` → counts + blindspot manifest present; grip via `tool grip_tool '{"tool":"..."}'` (no offset) → result says "(aligned to Semantic_Grip frame)".
- [ ] **Step 4: Poll-interval quick win:** set the dev bridge poll interval to 0.25s for this session (plugin setting `devBridgePollInterval`; see `src/Config.luau:61`) and note the observed tool round-trip improvement in the commit/report.
- [ ] **Step 5: Record** the battery results in the task report (verbatim outputs) for the Plan B acceptance demo.
