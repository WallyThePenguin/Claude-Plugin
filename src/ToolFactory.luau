--!strict
-- ToolFactory: the handheld-item engine. PURE gripCFrame (intuitive offset/rot -> a Tool.Grip CFrame) is
-- unit-tested in ToolFactorySpec; the impure toolify/resolveRig/equip/applyGrip (build the Tool + Handle +
-- welds, equip on a rig, set the live grip) are live-verified. Backs make_tool + grip_tool. See
-- docs/superpowers/specs/2026-06-24-handheld-item-creation-design.md.

local ToolFactory = {}

-- Rest cant: tip the blade FORWARD off the hand-up axis at the neutral pose. Pure fist-up
-- parallels a hanging forearm and embeds the blade ~1.5 studs in the arm (measured 2026-07-10);
-- classic Roblox tools cant forward via the RightGripAttachment C0 rotation. Sign/axis tuned
-- live: negative about hand X = toward -Z = character forward.
--
-- 50 deg = the USER-VALIDATED ready stance (grip-fitter-axis-mapping fix, 2026-07-11). The
-- fitter math maps ANY declared blade axis to the same canted-fist-up target, and for a
-- -Y-blade mesh on the stock R15 RightGripAttachment (-90 deg about X) that lands the Grip at
-- Angles(90 + cant, 0, 0) about X. All three live data points confirm the formula: the old
-- cant 18 produced the observed-bad 108 (18 + 90), and the hand-validated fixes 140 / 165
-- (StarterPack.Sword, edit-mode StepAnimations filmstrip) are exactly cant 50 / 75. So the
-- axis MAPPING was honest; the REST TARGET was wrong: 18 was tuned under grip_sane's
-- 35-degree blade_up_angle bound (metric pressure, not visual truth — anti-Goodhart lesson),
-- which parks the blade nearly parallel to the arm at rest and reads up-BACK over the
-- shoulder at any raised hold pose (the user's screenshot). NOTE: grip_sane's default
-- max_blade_angle (35) is now BELOW this cant — measure fitted grips with
-- {max_blade_angle = 55} until the oracle bound is recalibrated to the validated stance.
ToolFactory.REST_CANT_DEG = 50
-- Forward seat: the grip point rests this far forward of the palm center (hand -Z). Required,
-- not cosmetic: the block-rig arm is 1.0 stud thick and sits directly over the palm, so a cant
-- alone can't clear it inside the 35-degree bound (escape needs >50deg — measured 2026-07-10);
-- must stay under grip_sane's 0.6-stud grip_offset bound.
ToolFactory.REST_FORWARD_STUDS = 0.4

-- HOLD FRAME (user-validated 2026-07-25, "candidate B" — supersedes the 07-12 "candidate 2"
-- knuckles hold): when a mesh declares BOTH blade_dir and edge_dir, gripFromFrame aligns the FULL
-- handle frame — blade UP-FORWARD 45 deg out of the fist (the classic Roblox carry), cutting edge
-- forward-down, Semantic_Grip seated at the RightGripAttachment. WHY the change: the knuckles
-- hold was picked from STATIC candidates and read fine at rest, but under RETARGETED swing clips
-- the knuckles face BACKWARD in guard/cut phases, so the blade aimed behind the character (user:
-- "feels like the opposite direction" — confirmed on the side-view filmstrip comparison; the
-- animation-compatible hold keeps the blade forward through the arc). Method, again: render
-- candidates under the ACTUAL CLIP, let the user point. Constraining the edge still kills free
-- roll (the "sword on its side" bug). Hand-local unit directions (one source of truth —
-- grip_sane asserts THESE):
ToolFactory.HOLD_BLADE_DIR = Vector3.new(0, 1, -1).Unit -- blade up-forward 45 out of the fist
ToolFactory.HOLD_EDGE_DIR = Vector3.new(0, -1, -1).Unit -- edge forward-down (orthogonal to blade)

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

-- ---- impure (live-verified) ----

-- Collect a target's BaseParts: the part itself, or every BasePart under a Model.
local function collectParts(target: Instance): { BasePart }
	local parts: { BasePart } = {}
	if target:IsA("BasePart") then
		table.insert(parts, target :: BasePart)
	else
		for _, d in target:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d :: BasePart)
			end
		end
	end
	return parts
end

-- Resolve the Handle: a `handleHint` if it's one of `parts`; else the only part; else the Model's
-- PrimaryPart (if in parts); else the first part.
local function resolveHandle(parts: { BasePart }, target: Instance, handleHint: Instance?): BasePart
	if handleHint ~= nil and handleHint:IsA("BasePart") then
		for _, p in parts do
			if p == handleHint then
				return p
			end
		end
	end
	if #parts == 1 then
		return parts[1]
	end
	if target:IsA("Model") and (target :: Model).PrimaryPart ~= nil then
		local pp = (target :: Model).PrimaryPart
		for _, p in parts do
			if p == pp then
				return p
			end
		end
	end
	return parts[1]
end

-- The Motor6Ds that join two of the target's OWN parts — a builder-authored articulated chain
-- (weapon-as-limb, 2026-07-11: snake sword / flail segments jointed from the hilt up).
local function chainJointsAmong(target: Instance, parts: { BasePart }): { Motor6D }
	local inSet: { [Instance]: boolean } = {}
	for _, p in parts do
		inSet[p] = true
	end
	local joints: { Motor6D } = {}
	for _, d in target:GetDescendants() do
		if
			d:IsA("Motor6D")
			and d.Part0 ~= nil
			and d.Part1 ~= nil
			and inSet[d.Part0 :: Instance] == true
			and inSet[d.Part1 :: Instance] == true
		then
			table.insert(joints, d)
		end
	end
	return joints
end

-- Turn a built Part/Model into an equippable Tool. (Tool?, err?, chainCount). The Handle is renamed
-- "Handle"; parts reachable from it through builder-authored Motor6Ds are the ARTICULATED CHAIN and
-- keep their joints (each is an animatable pose channel — a WeldConstraint would freeze the joint
-- and fight the Animator); every other part is WeldConstraint'd to the Handle; all parts are
-- unanchored; chain joints are re-homed under their Part0 (they must ride the Tool, not die with
-- the emptied Model wrapper) and fit via fitChain; the wrapper is destroyed.
-- THROWS only on an engine failure (callers pcall); returns (nil, err) for a bad target.
function ToolFactory.toolify(
	target: Instance,
	handleHint: Instance?,
	toolName: string?
): (Tool?, string?, number)
	-- A target with a Humanoid is a RIG, not an item: toolifying it welds every body part to one
	-- Handle and parents the character into a Tool (the rig-inside-rig live mess, 2026-07-10).
	if target:FindFirstChildWhichIsA("Humanoid", true) ~= nil then
		return nil, "refusing to toolify a rig — target contains a Humanoid", 0
	end
	local parts = collectParts(target)
	if #parts == 0 then
		return nil, "no BaseParts under the target to make a Tool from", 0
	end
	local handle = resolveHandle(parts, target, handleHint)
	-- the chained set: parts connected to the Handle through Motor6Ds (undirected closure —
	-- a builder may point Part0 either way along the chain)
	local joints = chainJointsAmong(target, parts)
	local chained: { [Instance]: boolean } = { [handle] = true }
	local grew = true
	while grew do
		grew = false
		for _, j in joints do
			local a, b = j.Part0 :: Instance, j.Part1 :: Instance
			if chained[a] and not chained[b] then
				chained[b] = true
				grew = true
			end
			if chained[b] and not chained[a] then
				chained[a] = true
				grew = true
			end
		end
	end
	-- FIT THE CHAIN FIRST, while the parts are still ANCHORED in their built placement
	-- (live-caught 2026-07-11: the moment a Motor6D's parts are unanchored, the edit-mode
	-- assembly solver SNAPS Part1 to satisfy C0*Transform*C1^-1 — with the default identity
	-- C0/C1 that collapses every segment onto the Handle, and a fit computed afterwards
	-- freezes the collapse. Fit-then-unanchor makes the solver enforcement reproduce the
	-- built geometry instead of destroying it.)
	if #joints > 0 then
		ToolFactory.fitChain(target, handle) -- root = the handle: normalizes joint direction too
	end
	local tool = Instance.new("Tool")
	tool.Name = if toolName ~= nil and toolName ~= "" then toolName else target.Name
	tool.RequiresHandle = true
	tool.CanBeDropped = true
	handle.Anchored = false
	handle.Name = "Handle"
	if handle:FindFirstChild("Semantic_Grip") == nil then
		local att = Instance.new("Attachment")
		att.Name = "Semantic_Grip"
		att.Position = Vector3.zero -- candidate: handle center; stamp_frame refines
		att.Parent = handle
	end
	for _, p in parts do
		if p ~= handle then
			p.Anchored = false
			if not chained[p] then
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = handle
				wc.Part1 = p
				wc.Parent = handle
			end
			p.Parent = tool
		end
	end
	-- re-home chain joints under Part0 (the body-joint convention) BEFORE the wrapper dies
	local chainCount = 0
	for _, j in joints do
		local a, b = j.Part0 :: Instance, j.Part1 :: Instance
		if chained[a] and chained[b] then
			j.Parent = a
			chainCount += 1
		end
	end
	handle.Parent = tool
	tool.Parent = workspace
	if target:IsA("Model") and target ~= tool then
		target:Destroy()
	end
	return tool, nil, chainCount
end

-- Chain fit (weapon-as-limb, 2026-07-11): freeze the BUILT geometry into each chain joint's
-- C0/C1 so Transform=identity reproduces exactly the placement the builder authored:
--   C1 = the HINGE point in Part1-local space — Part0's center clamped into Part1's half-size
--        box (the near-face center), so a segment bends at its BASE, not about its center;
--   C0 = the Part0-relative placement folded through C1: Motor6D kinematics are
--        Part1.CFrame = Part0.CFrame * C0 * Transform * C1^-1, so at rest
--        C0 = Part0.CFrame^-1 * Part1.CFrame * C1 (exact by construction).
-- DIRECTION NORMALIZATION (review-caught 2026-07-11): every downstream consumer — the
-- weaponChildNames BFS, buildPoseTree/buildScopedPoses nesting, weapon_channel_of's chain
-- walk — follows Part0 -> Part1 AWAY from the grip, so a joint authored tip-down
-- (Part1 on the hilt side) would be kept and fit yet NEVER drivable, and a backwards
-- Part1="Handle" even clobbers the grip channel's pose nesting. When `root` is given
-- (the Handle), fitChain walks the chain outward from it and FLIPS any joint pointing
-- inward: swap Part0/Part1 and swap C0/C1 — rest-pose exact, since
-- P0 = P1 * C1 * C0^-1 is the same equation read backwards.
-- A REAL edit grip (a Motor6D named AgentEditGrip whose Part0 lives OUTSIDE the container,
-- i.e. the rig's hand) is skipped; a builder-authored joint that merely REUSES the reserved
-- name inside the weapon is healed (renamed after its Part1) and treated as chain — a
-- name-skip alone would leave it identity-C0/C1 and the unanchor solver would collapse it.
-- A joint whose C0 or C1 is already non-identity was authored deliberately and is left alone
-- (but still stamped + counted as a chain channel). Joints keeping the Instance.new default
-- name ("Motor6D") are renamed after their Part1 — pose channels are addressed by joint NAME
-- in add_keyframe poses maps (RigWorkbench.findJoint) and by PART name in the clip's Pose
-- tree; naming the joint after Part1 makes those coincide. Idempotent via SAChainFitted.
-- Returns (fittedCount, chainJointNames, flippedCount).
ToolFactory.CHAIN_FITTED_ATTR = "SAChainFitted"

function ToolFactory.fitChain(tool: Instance, root: BasePart?): (number, { string }, number)
	-- collect candidate chain joints (skip only the REAL grip: reserved name + Part0 outside)
	local joints: { Motor6D } = {}
	for _, d in tool:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			local p0In = (d.Part0 :: Instance) == tool or (d.Part0 :: Instance):IsDescendantOf(tool)
			if d.Name == "AgentEditGrip" then
				if not p0In then
					continue -- the rig's edit grip joint reaching into the tool — not ours to fit
				end
				-- reserved-name reuse: blank it now, the fit loop names it after the FINAL Part1
				-- (a rename here would bake the wrong name if the joint also needs flipping)
				d.Name = ""
			end
			table.insert(joints, d)
		end
	end
	-- direction normalization: BFS outward from the root, flipping inward-pointing joints
	local flipped = 0
	if root ~= nil then
		local touching: { [Instance]: { Motor6D } } = {}
		for _, j in joints do
			for _, p in { j.Part0 :: Instance, j.Part1 :: Instance } do
				if touching[p] == nil then
					touching[p] = {}
				end
				table.insert(touching[p], j)
			end
		end
		local seen: { [Instance]: boolean } = { [root :: Instance] = true }
		local queue: { Instance } = { root :: Instance }
		local head = 1
		while head <= #queue do
			local part = queue[head]
			head += 1
			for _, j in (touching[part] or {}) do
				local far: Instance = if (j.Part0 :: Instance) == part
					then j.Part1 :: Instance
					else j.Part0 :: Instance
				if not seen[far] then
					seen[far] = true
					if (j.Part1 :: Instance) == part then
						-- inward-pointing: flip so Part0 is on the root side (rest-exact swap)
						local p0, p1 = j.Part0, j.Part1
						local c0, c1 = j.C0, j.C1
						j.Part0 = p1
						j.Part1 = p0
						j.C0 = c1
						j.C1 = c0
						flipped += 1
					end
					table.insert(queue, far)
				end
			end
		end
	end
	local fitted = 0
	local names: { string } = {}
	for _, d in joints do
		local p0 = d.Part0 :: BasePart
		local p1 = d.Part1 :: BasePart
		if d.Name == "Motor6D" or d.Name == "" then
			d.Name = p1.Name
		end
		table.insert(names, d.Name)
		if d:GetAttribute(ToolFactory.CHAIN_FITTED_ATTR) ~= true then
			if d.C0 == CFrame.identity and d.C1 == CFrame.identity then
				local toward = p1.CFrame:PointToObjectSpace(p0.Position)
				local half = p1.Size / 2
				local hinge = Vector3.new(
					math.clamp(toward.X, -half.X, half.X),
					math.clamp(toward.Y, -half.Y, half.Y),
					math.clamp(toward.Z, -half.Z, half.Z)
				)
				local c1 = CFrame.new(hinge)
				d.C1 = c1
				d.C0 = p0.CFrame:ToObjectSpace(p1.CFrame * c1)
				d.Transform = CFrame.identity
				fitted += 1
			end
			d:SetAttribute(ToolFactory.CHAIN_FITTED_ATTR, true)
		end
	end
	return fitted, names, flipped
end

-- Resolve a rig: an explicit Model with a Humanoid, else the first workspace Model with a Humanoid +
-- RightHand. (Model?, err?).
function ToolFactory.resolveRig(rigInst: Instance?): (Model?, string?)
	if
		rigInst ~= nil
		and rigInst:IsA("Model")
		and rigInst:FindFirstChildOfClass("Humanoid") ~= nil
	then
		return rigInst :: Model, nil
	end
	for _, d in workspace:GetChildren() do
		if
			d:IsA("Model")
			and d:FindFirstChildOfClass("Humanoid") ~= nil
			and d:FindFirstChild("RightHand") ~= nil
		then
			return d :: Model, nil
		end
	end
	return nil, "no rig found — spawn one first with spawn_rig"
end

-- ---- arm-hold snapshot/restore (grip_tool arm-hold C0 residue, tooling issue 2026-07-11) ----
-- A hold pose written into joint C0 (e.g. RightShoulder ~37 / RightElbow ~31 deg) survives
-- unequip FOREVER unless something restores it: rigs kept the bent holding-arm, contaminating
-- rest-pose grip validation AND keypose snapshots. equip() snapshots EVERY Motor6D's C0/C1
-- into string attributes ON THE JOINT ITSELF; release() restores them and clears the
-- attributes. IDEMPOTENT: a joint that already carries a snapshot keeps its ORIGINAL pre-hold
-- values (re-equipping an already-held rig never re-snapshots the bent pose as "original").
ToolFactory.HOLD_C0_ATTR = "SAPreHoldC0"
ToolFactory.HOLD_C1_ATTR = "SAPreHoldC1"
-- Where the Tool lived before equip parented it to the rig (release re-homes it there).
ToolFactory.PRE_EQUIP_PARENT_ATTR = "SAPreEquipParent"

-- Exact 12-component CFrame <-> string (attributes; %.17g round-trips doubles losslessly).
local function cframeToString(cf: CFrame): string
	local comps = { cf:GetComponents() }
	local out: { string } = {}
	for _, n in comps do
		table.insert(out, string.format("%.17g", n))
	end
	return table.concat(out, ",")
end

local function cframeFromString(s: string): CFrame?
	local nums: { number } = {}
	for token in string.gmatch(s, "[^,]+") do
		local n = tonumber(token)
		if n == nil then
			return nil
		end
		table.insert(nums, n)
	end
	if #nums ~= 12 then
		return nil
	end
	local ok, cf = pcall(function(): CFrame
		return CFrame.new(table.unpack(nums))
	end)
	return if ok then cf else nil
end

-- Snapshot every rig joint's pre-hold C0/C1 (skips AgentEditGrip — ours, destroyed on release —
-- and Tool-INTERNAL joints: an articulated weapon's chain C0/C1 are its FIT, not a hold pose;
-- snapshotting them at equip would let release() revert a later re-fit, and they travel with
-- the Tool anyway).
local function snapshotHoldPose(rig: Model)
	for _, d in rig:GetDescendants() do
		if
			d:IsA("Motor6D")
			and d.Name ~= "AgentEditGrip"
			and d:FindFirstAncestorWhichIsA("Tool") == nil
		then
			if d:GetAttribute(ToolFactory.HOLD_C0_ATTR) == nil then
				d:SetAttribute(ToolFactory.HOLD_C0_ATTR, cframeToString(d.C0))
				d:SetAttribute(ToolFactory.HOLD_C1_ATTR, cframeToString(d.C1))
			end
		end
	end
end

-- Equip: parent the Tool to the rig AND joint the Handle to the RightHand. In EDIT mode the engine
-- creates NO grip weld (that only happens at runtime via Humanoid:EquipTool), so without this the
-- tool just sits wherever it was — inside the rig, not following the hand (observed live). The joint
-- is a Motor6D (SP2c): C0/C1 mirror the runtime RightGrip convention (C0 = RightGripAttachment
-- offset, C1 = Tool.Grip) so the edit preview renders the hold exactly as a running game would,
-- and because the Animator matches poses by CONNECTED PART NAMES (RightHand -> Handle), the Handle
-- becomes an animatable channel in edit. Idempotent: re-grip replaces the prior joint. Un-grip =
-- ToolFactory.release via grip_tool {release:true} (destroys "AgentEditGrip" — name is playbook
-- API surface — restores pre-hold joint C0/C1, and the caller re-homes the tool).
function ToolFactory.equip(tool: Tool, rig: Model)
	-- Remember where the Tool came from so release() can re-home it. Only stamped when the
	-- Tool arrives from OUTSIDE the rig (a re-grip on the same rig keeps the original origin).
	if tool.Parent ~= rig then
		local prior = tool.Parent
		tool:SetAttribute(
			ToolFactory.PRE_EQUIP_PARENT_ATTR,
			if prior ~= nil then prior:GetFullName() else ""
		)
	end
	-- EVICT the previously-equipped Tool (review-caught 2026-07-11): equip used to destroy
	-- only the grip motor, leaving the old Tool dangling INSIDE the rig — where its same-named
	-- parts (Handle, SegA...) trip joint_census's duplicate-channel FAIL and pollute the
	-- weapon census. Re-home any other Tool to where it came from (else StarterPack, the
	-- rig-destroy eviction convention).
	for _, child in rig:GetChildren() do
		if child:IsA("Tool") and child ~= tool then
			local priorPath = child:GetAttribute(ToolFactory.PRE_EQUIP_PARENT_ATTR)
			local dest: Instance? = nil
			if type(priorPath) == "string" and priorPath ~= "" then
				local ok, found = pcall(function()
					local cur: Instance? = game
					for token in string.gmatch(priorPath :: string, "[^%.]+") do
						if cur == nil then
							return nil
						end
						if token == "game" then
							cur = game
						elseif cur == game then
							cur = game:GetService(token) :: Instance
						else
							cur = (cur :: Instance):FindFirstChild(token)
						end
					end
					return cur
				end)
				if ok and found ~= nil and found ~= game then
					dest = found :: Instance
				end
			end
			child.Parent = if dest ~= nil then dest else game:GetService("StarterPack")
			child:SetAttribute(ToolFactory.PRE_EQUIP_PARENT_ATTR, nil)
		end
	end
	tool.Parent = rig
	local hand = rig:FindFirstChild("RightHand")
	local handle = tool:FindFirstChild("Handle")
	if hand == nil or not hand:IsA("BasePart") or handle == nil or not handle:IsA("BasePart") then
		return -- no hand/handle to weld; the tool is merely parented
	end
	-- Pre-hold snapshot BEFORE any hold-pose C0 writes can land on this rig (idempotent).
	snapshotHoldPose(rig)
	for _, p in tool:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false -- an anchored part ignores the weld and stays put
		end
	end
	local stale = hand:FindFirstChild("AgentEditGrip")
	if stale ~= nil then
		stale:Destroy()
	end
	-- Purge a stale RUNTIME grip weld too (live-caught 2026-07-12): a `RightGrip` Weld left on
	-- the hand by a Humanoid:EquipTool play cycle is RIGID and out-competes our Motor6D in the
	-- edit-mode solve — every C0/C1 grip edit becomes a silent no-op (the sword rides the stock
	-- attachment * tool.Grip pose instead). One Handle, one authority: AgentEditGrip.
	local staleRuntime = hand:FindFirstChild("RightGrip")
	if staleRuntime ~= nil and staleRuntime:IsA("Weld") then
		staleRuntime:Destroy()
	end
	local att = hand:FindFirstChild("RightGripAttachment")
	local weld = Instance.new("Motor6D")
	weld.Name = "AgentEditGrip"
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = if att ~= nil and att:IsA("Attachment") then att.CFrame else CFrame.new()
	weld.C1 = tool.Grip
	weld.Parent = hand
end

-- Set the live grip CFrame; keeps the edit-mode grip joint's C1 in sync so the Handle re-positions.
-- JointInstance covers both the Motor6D and any stale pre-SP2c Weld still on a rig.
function ToolFactory.applyGrip(tool: Tool, grip: CFrame)
	tool.Grip = grip
	local rig = tool.Parent
	if rig ~= nil and rig:IsA("Model") then
		local hand = rig:FindFirstChild("RightHand")
		local weld = if hand ~= nil then hand:FindFirstChild("AgentEditGrip") else nil
		if weld ~= nil and weld:IsA("JointInstance") then
			weld.C1 = grip
		end
	end
end

-- Frame-aware grip (SP2): when the Handle carries a stamped semantic frame (Semantic_Grip
-- attachment + SemanticFrame attribute from stamp_frame), compute the Grip CFrame that
-- places the declared grip point in the palm with blade_dir along the hand's up axis —
-- mis-grips become impossible rather than merely detectable. Returns nil when the frame
-- is absent (caller falls back to offset/rot mode). The optional rig lets the math fold
-- in the hand's RightGripAttachment rotation (stock R15: -90deg about X); without it the
-- attachment rotation is assumed identity.
local function rotFromTo(a: Vector3, b: Vector3): CFrame
	local d = math.clamp(a:Dot(b), -1, 1)
	if d > 0.9999 then
		return CFrame.new()
	end
	if d < -0.9999 then
		local axis = if math.abs(a.X) < 0.9
			then a:Cross(Vector3.xAxis).Unit
			else a:Cross(Vector3.yAxis).Unit
		return CFrame.fromAxisAngle(axis, math.pi)
	end
	return CFrame.fromAxisAngle(a:Cross(b).Unit, math.acos(d))
end

-- holdBlade/holdEdge: optional HAND-LOCAL overrides of the HOLD convention (candidate-rendering
-- seam, 2026-07-25 — "render candidates, let the user point"; omit for the doctrine constants).
function ToolFactory.gripFromFrame(
	tool: Tool,
	rig: Model?,
	holdBlade: Vector3?,
	holdEdge: Vector3?
): CFrame?
	local handle = tool:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		return nil
	end
	local att = handle:FindFirstChild("Semantic_Grip")
	if att == nil or not att:IsA("Attachment") then
		return nil
	end
	-- Only align when stamp_frame actually ran: the toolify candidate attachment alone
	-- must stay passive (legacy identity-grip behavior otherwise).
	local raw = handle:GetAttribute("SemanticFrame")
	if type(raw) ~= "string" then
		return nil
	end
	local okDecode, decoded = pcall(function()
		return game:GetService("HttpService"):JSONDecode(raw)
	end)
	if
		not okDecode
		or type(decoded) ~= "table"
		or type(decoded.dirs) ~= "table"
		or type(decoded.dirs.blade_dir) ~= "table"
	then
		return nil
	end
	local d = decoded.dirs.blade_dir
	local blade = Vector3.new(tonumber(d.x) or 0, tonumber(d.y) or 0, tonumber(d.z) or 0)
	if blade.Magnitude < 1e-4 then
		return nil
	end
	blade = blade.Unit

	-- HOLD-FRAME path (candidate 2, 2026-07-12): if the mesh also declares edge_dir, constrain BOTH
	-- axes (a full frame alignment) and return early. Only when edge_dir is ABSENT do we fall through
	-- to the legacy blade-only cant below. This is the durable fix for "the sword is on its side":
	-- the old path left roll free, so the edge landed wherever rotFromTo's minimal rotation put it.
	local ed = decoded.dirs.edge_dir
	if type(ed) == "table" then
		local edge = Vector3.new(tonumber(ed.x) or 0, tonumber(ed.y) or 0, tonumber(ed.z) or 0)
		edge = edge - blade * edge:Dot(blade) -- Gram-Schmidt: make edge orthogonal to blade
		if edge.Magnitude > 1e-4 then
			edge = edge.Unit
			-- Attachment frame + grip point (stock R15 fallback when the rig/attachment is absent).
			local attCF = CFrame.new(0, -0.158, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
			if rig ~= nil then
				local hand = rig:FindFirstChild("RightHand", true)
				local gripAtt = if hand ~= nil
					then hand:FindFirstChild("RightGripAttachment")
					else nil
				if gripAtt ~= nil and gripAtt:IsA("Attachment") then
					attCF = gripAtt.CFrame
				end
			end
			-- R (handle-local -> hand-local) maps the handle's (edge=X, blade=Y) frame onto the
			-- hand-local hold frame (HOLD_EDGE_DIR=X, HOLD_BLADE_DIR=Y), overridable per call.
			local hb = (holdBlade or ToolFactory.HOLD_BLADE_DIR).Unit
			local he = holdEdge or ToolFactory.HOLD_EDGE_DIR
			he = (he - hb * he:Dot(hb)).Unit -- keep the hold frame orthonormal too
			local R = CFrame.fromMatrix(Vector3.zero, he, hb)
				* CFrame.fromMatrix(Vector3.zero, edge, blade):Inverse()
			-- Seat the Semantic_Grip point at the attachment, then fold through equip's convention
			-- (Handle-in-hand = attCF * Grip^-1) so bind_grip_motor + the runtime RightGrip keep
			-- working unchanged: Grip = rel^-1 * attCF.
			local rel = CFrame.new(attCF.Position - R:PointToWorldSpace(att.Position)) * R
			return rel:Inverse() * attCF
		end
	end

	-- INVARIANT (grip-fitter-axis-mapping, 2026-07-11): the fitted blade WORLD direction at
	-- rest ~= the fist-up axis rotated REST_CANT_DEG forward, REGARDLESS of the mesh's local
	-- blade axis. rotFromTo maps the declared blade_dir onto the canted target expressed in
	-- RightGripAttachment space, so Grip^-1 * blade_dir = target BY CONSTRUCTION for any
	-- blade_dir (+X, -Y, anything). On the stock R15 attachment (-90 deg about X) the Grip
	-- rotation family about X is (90 + cant) for a -Y blade and (cant - 90) for a +Y blade;
	-- the validated StarterPack.Sword grip Angles(rad(140),0,0) is the 50-deg-cant image of
	-- its -Y blade. Verified against tonight's three data points: cant 18 -> 108 (observed
	-- bad), 50 -> 140 and 75 -> 165 (hand-validated good).
	--
	-- Rest cant + forward seat (hand space): rotate the target axis off pure fist-up about the
	-- hand's X so the blade tips FORWARD (-Z) instead of paralleling the hanging forearm, and
	-- seat the grip point forward of the palm center (blade-in-arm fix, both tuned live).
	local canted = CFrame.fromAxisAngle(Vector3.xAxis, math.rad(-ToolFactory.REST_CANT_DEG))
		* Vector3.yAxis
	local seat = Vector3.new(0, 0, -ToolFactory.REST_FORWARD_STUDS)
	local v = canted
	local s = seat
	if rig ~= nil then
		local hand = rig:FindFirstChild("RightHand", true)
		local gripAtt = if hand ~= nil then hand:FindFirstChild("RightGripAttachment") else nil
		if gripAtt ~= nil and gripAtt:IsA("Attachment") then
			v = gripAtt.CFrame:VectorToObjectSpace(canted)
			s = gripAtt.CFrame:VectorToObjectSpace(seat)
		end
	end
	-- Grip = T * R with T chosen so the declared grip point lands at palm + seat (grip_sane's
	-- gripWorld = hand * C0 * s when T = att.Position - R*s).
	local rot = rotFromTo(v, blade)
	return CFrame.new(att.Position - rot:VectorToWorldSpace(s)) * rot
end

-- Off-hand IK grip (SP2c item 6): stamp/reuse a Semantic_OffHand Attachment on the Handle and aim a
-- LeftUpperArm->LeftHand IKControl at it (IKControl.Target accepts an Attachment — Roblox Weapons Kit
-- prior art; IKControl must live under a Humanoid that has an Animator). Type=Position: the hand
-- REACHES the point without inheriting the attachment's orientation (a wrong wrist roll is worse than
-- none; Transform mode is a follow-up). `localPos` (optional, Handle-local studs) moves the attachment;
-- default = the Semantic_Grip position (both hands on the grip — move the attachment to refine).
-- enabled=false removes the control. Idempotent: re-call replaces the prior control. Returns (note, ok).
local OFFHAND_ATT = "Semantic_OffHand"
local OFFHAND_IK = "AgentOffHandIK"

function ToolFactory.setOffHand(
	tool: Tool,
	rig: Model,
	enabled: boolean,
	localPos: Vector3?
): (string, boolean)
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return "no Humanoid on " .. rig.Name .. " — off-hand IK needs a Humanoid rig.", false
	end
	local stale = humanoid:FindFirstChild(OFFHAND_IK)
	if stale ~= nil then
		stale:Destroy()
	end
	if not enabled then
		return "off-hand IK removed.", true
	end
	local handle = tool:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		return "tool '" .. tool.Name .. "' has no Handle part.", false
	end
	local chainRoot = rig:FindFirstChild("LeftUpperArm")
	local endEffector = rig:FindFirstChild("LeftHand")
	if chainRoot == nil or endEffector == nil then
		return "rig has no LeftUpperArm/LeftHand (off-hand IK needs an R15 rig).", false
	end
	if humanoid:FindFirstChildOfClass("Animator") == nil then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local att = handle:FindFirstChild(OFFHAND_ATT)
	if att == nil or not att:IsA("Attachment") then
		local na = Instance.new("Attachment")
		na.Name = OFFHAND_ATT
		local gripAtt = handle:FindFirstChild("Semantic_Grip")
		na.Position = if gripAtt ~= nil and gripAtt:IsA("Attachment")
			then gripAtt.Position
			else Vector3.zero
		na.Parent = handle
		att = na
	end
	local theAtt = att :: Attachment
	if localPos ~= nil then
		theAtt.Position = localPos
	end
	local ik = Instance.new("IKControl")
	ik.Name = OFFHAND_IK
	ik.Type = Enum.IKControlType.Position
	ik.ChainRoot = chainRoot
	ik.EndEffector = endEffector
	ik.Target = theAtt
	ik.Parent = humanoid
	return "off-hand IK: LeftHand reaches "
		.. theAtt:GetFullName()
		.. " (IKControl '"
		.. OFFHAND_IK
		.. "' under the Humanoid).",
		true
end

-- Release (the un-equip surface, grip_tool {release:true}): destroy the AgentEditGrip motor,
-- remove the off-hand IK, restore every joint's pre-hold C0/C1 from the equip-time
-- snapshot (clearing the snapshot attributes), and ZERO the tool's own chain Motor6D
-- Transforms (review-caught 2026-07-11: keypose residue on segment joints survived release —
-- the caller's resetPose runs on the RIG after the Tool is re-homed out of it, and the
-- hold-pose snapshot deliberately skips Tool-internal joints, so a released snake sword
-- stayed frozen mid-curl and the curl re-entered the next authoring session's snapshots).
-- Returns the number of joints whose C0 was restored. The CALLER also purges playing
-- tracks, resets rig Motor6D Transforms + StepAnimations (so the restore is visible), and
-- re-homes the Tool via PRE_EQUIP_PARENT_ATTR.
function ToolFactory.release(tool: Tool, rig: Model): number
	for _, d in tool:GetDescendants() do
		if d:IsA("Motor6D") then
			d.Transform = CFrame.identity
		end
	end
	-- FLUSH the zeroed Transforms into part placement while the Tool is still under the rig:
	-- writing a part CFrame would teleport the whole rigid ASSEMBLY (measured: it dragged the
	-- chain 0.07 studs and kept the bend), but one StepAnimations pass re-solves every joint
	-- from C0/C1/Transform — the exact pose_joint/applyPose pattern. Without it a released
	-- tool has no Animator and stays visibly frozen mid-pose until the next equip.
	local controller: Instance? = rig:FindFirstChildOfClass("Humanoid")
		or rig:FindFirstChildOfClass("AnimationController")
	if controller ~= nil then
		local animator = controller:FindFirstChildOfClass("Animator")
		if animator == nil then
			local na = Instance.new("Animator")
			na.Parent = controller
			animator = na
		end
		pcall(function()
			(animator :: Animator):StepAnimations(0)
		end)
	end
	return ToolFactory.releaseRig(rig)
end

-- The rig-side half of release (grip motor + IK + hold-pose restore) — split so release()
-- can zero the tool chain first while keeping one code path for the rig restore.
function ToolFactory.releaseRig(rig: Model): number
	local hand = rig:FindFirstChild("RightHand")
	if hand ~= nil then
		local weld = hand:FindFirstChild("AgentEditGrip")
		if weld ~= nil then
			weld:Destroy()
		end
	end
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		local ik = humanoid:FindFirstChild(OFFHAND_IK)
		if ik ~= nil then
			ik:Destroy()
		end
	end
	local restored = 0
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			local rawC0 = d:GetAttribute(ToolFactory.HOLD_C0_ATTR)
			if type(rawC0) == "string" then
				local c0 = cframeFromString(rawC0)
				if c0 ~= nil then
					d.C0 = c0
					restored += 1
				end
			end
			local rawC1 = d:GetAttribute(ToolFactory.HOLD_C1_ATTR)
			if type(rawC1) == "string" then
				local c1 = cframeFromString(rawC1)
				if c1 ~= nil then
					d.C1 = c1
				end
			end
			d:SetAttribute(ToolFactory.HOLD_C0_ATTR, nil)
			d:SetAttribute(ToolFactory.HOLD_C1_ATTR, nil)
		end
	end
	return restored
end

return ToolFactory
