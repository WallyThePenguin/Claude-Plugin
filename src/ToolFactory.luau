--!strict
-- ToolFactory: the handheld-item engine. PURE gripCFrame (intuitive offset/rot -> a Tool.Grip CFrame) is
-- unit-tested in ToolFactorySpec; the impure toolify/resolveRig/equip/applyGrip (build the Tool + Handle +
-- welds, equip on a rig, set the live grip) are live-verified. Backs make_tool + grip_tool. See
-- docs/superpowers/specs/2026-06-24-handheld-item-creation-design.md.

local ToolFactory = {}

-- Rest cant: tip the blade FORWARD off the hand-up axis at the neutral pose. Pure fist-up
-- parallels a hanging forearm and embeds the blade ~1.5 studs in the arm (measured 2026-07-10);
-- classic Roblox tools cant forward via the RightGripAttachment C0 rotation. Must stay under
-- grip_sane's 35-degree blade_up_angle bound. Sign/axis tuned live: negative about hand X =
-- toward -Z = character forward.
ToolFactory.REST_CANT_DEG = 18
-- Forward seat: the grip point rests this far forward of the palm center (hand -Z). Required,
-- not cosmetic: the block-rig arm is 1.0 stud thick and sits directly over the palm, so a cant
-- alone can't clear it inside the 35-degree bound (escape needs >50deg — measured 2026-07-10);
-- must stay under grip_sane's 0.6-stud grip_offset bound.
ToolFactory.REST_FORWARD_STUDS = 0.4

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

-- Turn a built Part/Model into an equippable Tool. (Tool?, err?). The Handle is renamed "Handle"; every
-- other part is WeldConstraint'd to it; all parts are unanchored; an emptied Model wrapper is destroyed.
-- THROWS only on an engine failure (callers pcall); returns (nil, err) for a bad target.
function ToolFactory.toolify(
	target: Instance,
	handleHint: Instance?,
	toolName: string?
): (Tool?, string?)
	local parts = collectParts(target)
	if #parts == 0 then
		return nil, "no BaseParts under the target to make a Tool from"
	end
	local handle = resolveHandle(parts, target, handleHint)
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
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = handle
			wc.Part1 = p
			wc.Parent = handle
			p.Parent = tool
		end
	end
	handle.Parent = tool
	tool.Parent = workspace
	if target:IsA("Model") and target ~= tool then
		target:Destroy()
	end
	return tool, nil
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

-- Equip: parent the Tool to the rig AND joint the Handle to the RightHand. In EDIT mode the engine
-- creates NO grip weld (that only happens at runtime via Humanoid:EquipTool), so without this the
-- tool just sits wherever it was — inside the rig, not following the hand (observed live). The joint
-- is a Motor6D (SP2c): C0/C1 mirror the runtime RightGrip convention (C0 = RightGripAttachment
-- offset, C1 = Tool.Grip) so the edit preview renders the hold exactly as a running game would,
-- and because the Animator matches poses by CONNECTED PART NAMES (RightHand -> Handle), the Handle
-- becomes an animatable channel in edit. Idempotent: re-grip replaces the prior joint. Un-grip =
-- destroy the "AgentEditGrip" instance (name is playbook API surface) + reparent the tool out.
function ToolFactory.equip(tool: Tool, rig: Model)
	tool.Parent = rig
	local hand = rig:FindFirstChild("RightHand")
	local handle = tool:FindFirstChild("Handle")
	if hand == nil or not hand:IsA("BasePart") or handle == nil or not handle:IsA("BasePart") then
		return -- no hand/handle to weld; the tool is merely parented
	end
	for _, p in tool:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false -- an anchored part ignores the weld and stays put
		end
	end
	local stale = hand:FindFirstChild("AgentEditGrip")
	if stale ~= nil then
		stale:Destroy()
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
		local axis = if math.abs(a.X) < 0.9 then a:Cross(Vector3.xAxis).Unit else a:Cross(Vector3.yAxis).Unit
		return CFrame.fromAxisAngle(axis, math.pi)
	end
	return CFrame.fromAxisAngle(a:Cross(b).Unit, math.acos(d))
end

function ToolFactory.gripFromFrame(tool: Tool, rig: Model?): CFrame?
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
	if not okDecode or type(decoded) ~= "table" or type(decoded.dirs) ~= "table" or type(decoded.dirs.blade_dir) ~= "table" then
		return nil
	end
	local d = decoded.dirs.blade_dir
	local blade = Vector3.new(tonumber(d.x) or 0, tonumber(d.y) or 0, tonumber(d.z) or 0)
	if blade.Magnitude < 1e-4 then
		return nil
	end
	blade = blade.Unit
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
	return "off-hand IK: LeftHand reaches " .. theAtt:GetFullName() .. " (IKControl '" .. OFFHAND_IK .. "' under the Humanoid).",
		true
end

return ToolFactory
