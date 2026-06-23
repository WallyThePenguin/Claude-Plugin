--!strict
-- GuiEvidence: structural evidence for GUI/UI subjects, for evaluate's grader. PURE helpers (scale-vs-offset
-- detection, the layout summary) are unit-tested; the impure gather() walks a subject's GuiObjects + UI
-- classes. Mirrors the capture/animation pure+impure split. Lets evaluate grade non-animation categories
-- (e.g. gui) on real structure instead of the animation-only census. "" when the subject has no GUI.

local GuiEvidence = {}

local UI_CLASSES = {
	"Frame",
	"TextLabel",
	"TextButton",
	"ImageLabel",
	"ImageButton",
	"ScrollingFrame",
	"TextBox",
	"UIListLayout",
	"UIGridLayout",
	"UIPageLayout",
	"UITableLayout",
	"UIPadding",
	"UICorner",
	"UIAspectRatioConstraint",
	"UISizeConstraint",
	"UIStroke",
	"UIGradient",
	"UIScale",
}

local UI_SET: { [string]: boolean } = {}
for _, c in UI_CLASSES do
	UI_SET[c] = true
end

local LAYOUT_CLASSES: { [string]: boolean } =
	{ UIListLayout = true, UIGridLayout = true, UIPageLayout = true, UITableLayout = true }

local MAX_ELEMENTS = 60 -- cap the per-element walk

export type Fact = {
	scaleSize: boolean,
	scalePos: boolean,
	anchor: boolean,
	layout: boolean,
	corner: boolean,
	padding: boolean,
	constraint: boolean,
}

-- ---- pure ----

-- A UDim2 axis "uses scale" if either scale component is non-zero (responsive vs fixed-offset).
function GuiEvidence.usesScale(scaleX: number, scaleY: number): boolean
	return scaleX ~= 0 or scaleY ~= 0
end

-- Summarize a list of element facts into a one-paragraph evidence line. "" if no facts.
function GuiEvidence.summarizeLayout(facts: { Fact }): string
	local n = #facts
	if n == 0 then
		return ""
	end
	local scaleSize, scalePos, anchor, layout, corner, padding, constraint = 0, 0, 0, 0, 0, 0, 0
	for _, f in facts do
		if f.scaleSize then
			scaleSize += 1
		end
		if f.scalePos then
			scalePos += 1
		end
		if f.anchor then
			anchor += 1
		end
		if f.layout then
			layout += 1
		end
		if f.corner then
			corner += 1
		end
		if f.padding then
			padding += 1
		end
		if f.constraint then
			constraint += 1
		end
	end
	return string.format(
		"GUI layout (of %d elements sampled): %d use scale-based Size, %d scale-based Position (vs offset-only); "
			.. "%d set AnchorPoint; %d have a UIListLayout/UIGridLayout; %d have UICorner; %d have UIPadding; "
			.. "%d have a UI constraint (aspect/size).",
		n,
		scaleSize,
		scalePos,
		anchor,
		layout,
		corner,
		padding,
		constraint
	)
end

-- ---- impure ----

-- Census the UI classes under the subject + summarize per-element layout quality. "" if no GUI present.
function GuiEvidence.gather(subject: Instance): string
	local census: { [string]: number } = {}
	local guiCount = 0
	for _, d in subject:GetDescendants() do
		if UI_SET[d.ClassName] then
			census[d.ClassName] = (census[d.ClassName] or 0) + 1
			guiCount += 1
		end
	end
	if guiCount == 0 then
		return ""
	end
	local facts: { Fact } = {}
	for _, d in subject:GetDescendants() do
		if #facts >= MAX_ELEMENTS then
			break
		end
		if d:IsA("GuiObject") then
			local obj = d :: GuiObject
			local hasLayout, hasCorner, hasPadding, hasConstraint = false, false, false, false
			for _, c in (d :: Instance):GetChildren() do
				if LAYOUT_CLASSES[c.ClassName] then
					hasLayout = true
				end
				if c.ClassName == "UICorner" then
					hasCorner = true
				end
				if c.ClassName == "UIPadding" then
					hasPadding = true
				end
				if c:IsA("UIConstraint") then
					hasConstraint = true
				end
			end
			table.insert(facts, {
				scaleSize = GuiEvidence.usesScale(obj.Size.X.Scale, obj.Size.Y.Scale),
				scalePos = GuiEvidence.usesScale(obj.Position.X.Scale, obj.Position.Y.Scale),
				anchor = obj.AnchorPoint.X ~= 0 or obj.AnchorPoint.Y ~= 0,
				layout = hasLayout,
				corner = hasCorner,
				padding = hasPadding,
				constraint = hasConstraint,
			})
		end
	end
	local cl: { string } = {}
	for k, v in census do
		table.insert(cl, k .. "=" .. tostring(v))
	end
	table.sort(cl)
	local parts: { string } = { "GUI classes: " .. table.concat(cl, ", ") }
	local summary = GuiEvidence.summarizeLayout(facts)
	if summary ~= "" then
		table.insert(parts, summary)
	end
	return table.concat(parts, "\n")
end

return GuiEvidence
