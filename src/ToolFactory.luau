--!strict
-- ToolFactory: the handheld-item engine. PURE gripCFrame (intuitive offset/rot -> a Tool.Grip CFrame) is
-- unit-tested in ToolFactorySpec; the impure toolify/resolveRig/equip/applyGrip (build the Tool + Handle +
-- welds, equip on a rig, set the live grip) are live-verified. Backs make_tool + grip_tool. See
-- docs/superpowers/specs/2026-06-24-handheld-item-creation-design.md.

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

-- Equip: parent the Tool to the rig AND weld the Handle to the RightHand. In EDIT mode the engine
-- creates NO grip weld (that only happens at runtime via Humanoid:EquipTool), so without this the
-- tool just sits wherever it was — inside the rig, not following the hand (observed live). The weld
-- mirrors the runtime RightGrip convention (C0 = RightGripAttachment offset, C1 = Tool.Grip), so
-- the edit preview renders the hold exactly as a running game would. Idempotent: re-grip replaces
-- the prior weld. Un-grip = destroy the "AgentEditGrip" weld + reparent the tool out.
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
	local weld = Instance.new("Weld")
	weld.Name = "AgentEditGrip"
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = if att ~= nil and att:IsA("Attachment") then att.CFrame else CFrame.new()
	weld.C1 = tool.Grip
	weld.Parent = hand
end

-- Set the live grip CFrame; keeps the edit-mode grip weld's C1 in sync so the Handle re-positions.
function ToolFactory.applyGrip(tool: Tool, grip: CFrame)
	tool.Grip = grip
	local rig = tool.Parent
	if rig ~= nil and rig:IsA("Model") then
		local hand = rig:FindFirstChild("RightHand")
		local weld = if hand ~= nil then hand:FindFirstChild("AgentEditGrip") else nil
		if weld ~= nil and weld:IsA("Weld") then
			weld.C1 = grip
		end
	end
end

return ToolFactory
