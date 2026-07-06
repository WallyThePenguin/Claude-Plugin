--!strict
-- ============================================================================================
--  UIEngine  —  a standalone, reusable framework for building AAA-quality Roblox GUIs.
--  Install as a ModuleScript at ReplicatedStorage.UIEngine and `require` it from any script.
--
--  It is NOT this game's UI. It is the BACKEND that any UI is built on. It provides:
--    • Theme        — design tokens (color/font/space/radius/shadow/motion) + reskin in one place
--    • create()     — a declarative element builder (describe UI as a tree, not imperative spam)
--    • fx           — the AAA polish primitives (corner/gradient/stroke/rim/shadow/glow/highlight)
--    • layout       — responsive helpers (list/grid/pad/aspect/scaleToViewport)
--    • motion       — springs, pops, hover/press, pulse, shine-sweep, enter/exit transitions
--    • State/bind   — a tiny reactive value so UI updates itself when data changes
--    • Components    — Panel/Button/Card/Pill/Badge/IconChip/ProgressBar/StatBar/Modal/Divider/Toast
--
--  Everything renders from Roblox UI primitives + native UIShadow — ZERO uploaded assets.
-- ============================================================================================
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local UI = {}

-- =================================== THEME (design tokens) ===================================
local T = {}
T.color = {
	bg = Color3.fromRGB(13, 15, 28), deep = Color3.fromRGB(20, 24, 44),
	surface = Color3.fromRGB(28, 33, 58), surfaceHi = Color3.fromRGB(54, 62, 102),
	raised = Color3.fromRGB(40, 46, 78), surfaceLo = Color3.fromRGB(17, 21, 30),
	overlay = Color3.fromRGB(6, 8, 12), ink = Color3.fromRGB(6, 8, 12),
	hairline = Color3.fromRGB(92, 104, 160), strokeHi = Color3.fromRGB(150, 168, 235),
	primary = Color3.fromRGB(108, 140, 255), secondary = Color3.fromRGB(168, 120, 255),
	cyan = Color3.fromRGB(88, 224, 255), accent = Color3.fromRGB(168, 120, 255),
	gold = Color3.fromRGB(255, 200, 88), pink = Color3.fromRGB(255, 110, 190),
	success = Color3.fromRGB(80, 224, 150), warning = Color3.fromRGB(255, 178, 64), danger = Color3.fromRGB(255, 84, 104),
	text = Color3.fromRGB(245, 247, 255), textMid = Color3.fromRGB(190, 198, 225),
	textDim = Color3.fromRGB(128, 138, 170), textOnAccent = Color3.fromRGB(12, 14, 26),
}
T.font = { display = Enum.Font.LuckiestGuy, heading = Enum.Font.GothamBlack, body = Enum.Font.GothamBold, med = Enum.Font.GothamMedium }
T.tsize = { xs = 13, sm = 14, md = 16, lg = 20, xl = 26, xxl = 34, hero = 46 }
T.space = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }
T.radius = { sm = 6, md = 10, lg = 16, xl = 22, pill = 1000 }
T.stroke = { hair = 1, thin = 2, bold = 3 }
T.shadow = { -- native UIShadow tiers (blur px, spread px, offset-y px, transparency)
	sm = { blur = 8, spread = 0, oy = 2, tr = 0.55 },
	md = { blur = 18, spread = 1, oy = 4, tr = 0.45 },
	lg = { blur = 34, spread = 2, oy = 10, tr = 0.34 },
	glow = { blur = 26, spread = 6, oy = 0, tr = 0.36 },
}
T.z = { base = 1, raised = 10, sticky = 50, hud = 100, modal = 1000, toast = 2000 }
T.motion = {
	fast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	base = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	slow = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	spring = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	pulse = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
}
UI.Theme = T
UI.T = T -- terse alias
local function role(r: any): Color3 return (typeof(r) == "Color3" and r) or (r and T.color[r]) or T.color.primary end
UI.role = role

-- =============================== create() — declarative builder ==============================
-- create("Frame", { props }, { children }) -> Instance. Props: Roblox props + special keys:
--   Corner=n, Pad=n, List={horizontal,gap,align}, Gradient=ColorSequence|table, Stroke={...},
--   Shadow="md", Glow=Color3, Parent=inst. Children are parented in order (LayoutOrder auto).
function UI.create(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local inst = Instance.new(className)
	props = props or {}
	local special = props.__special or {}
	for k, v in props do
		if k ~= "__special" and k ~= "Parent" then
			local ok = pcall(function() (inst :: any)[k] = v end)
			if not ok then special[k] = v end
		end
	end
	if children then
		for i, c in children do
			if c:IsA("GuiObject") and c.LayoutOrder == 0 then c.LayoutOrder = i end
			c.Parent = inst
		end
	end
	if props.Parent then inst.Parent = props.Parent end
	return inst
end

-- ================================ fx — AAA polish primitives =================================
local fx = {}
function fx.corner(p: Instance, r: number?): UICorner
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or T.radius.md); c.Parent = p; return c
end
function fx.gradient(p: Instance, colorSeq: ColorSequence?, rot: number?, transSeq: NumberSequence?): UIGradient
	local g = Instance.new("UIGradient"); g.Rotation = rot or 90
	if colorSeq then g.Color = colorSeq end; if transSeq then g.Transparency = transSeq end; g.Parent = p; return g
end
function fx.stroke(p: Instance, col: Color3?, th: number?, tr: number?): UIStroke
	local s = Instance.new("UIStroke"); s.Color = col or T.color.hairline; s.Thickness = th or T.stroke.thin
	s.Transparency = tr or 0; s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; s.LineJoinMode = Enum.LineJoinMode.Round; s.Parent = p; return s
end
-- premium rim: white stroke tinted accent(top)->ink(bottom) = a lit bevel edge
function fx.rim(p: Instance, accent: any, th: number?): UIStroke
	local s = fx.stroke(p, Color3.new(1, 1, 1), th or T.stroke.bold, 0)
	fx.gradient(s, ColorSequence.new({ ColorSequenceKeypoint.new(0, role(accent)), ColorSequenceKeypoint.new(1, T.color.ink) }), 90)
	return s
end
-- native soft shadow (behind parent). Spread + Offset are UDim2 (verified). pcall-guarded fully.
function fx.shadow(p: Instance, tier: string?, color: Color3?): Instance?
	local sd = T.shadow[tier or "md"]; if not sd then return nil end
	local ok, sh = pcall(function()
		local s = Instance.new("UIShadow")
		s.BlurRadius = UDim.new(0, sd.blur)
		s.Spread = UDim2.fromOffset(sd.spread, sd.spread)
		s.Offset = UDim2.fromOffset(0, sd.oy)
		s.Transparency = sd.tr
		s.Color = color or T.color.ink
		s.Parent = p
		return s
	end)
	return ok and sh or nil
end
-- colored halo glow (offset 0, wide spread)
function fx.glow(p: Instance, color: Color3?): Instance?
	local sd = T.shadow.glow
	local ok, sh = pcall(function()
		local s = Instance.new("UIShadow")
		s.BlurRadius = UDim.new(0, sd.blur); s.Spread = UDim2.fromOffset(sd.spread, sd.spread)
		s.Offset = UDim2.fromOffset(0, 0); s.Transparency = sd.tr; s.Color = color or T.color.primary; s.Parent = p
		return s
	end)
	return ok and sh or nil
end
-- thick dark GLYPH outline (the juicy gacha/anime display-type look). Contextual = outlines the text.
function fx.textOutline(label: TextLabel, color: Color3?, th: number?): UIStroke
	local s = Instance.new("UIStroke"); s.Color = color or T.color.ink; s.Thickness = th or 3
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual; s.LineJoinMode = Enum.LineJoinMode.Round; s.Parent = label
	return s
end
-- 2-tone anime highlight sheen across the top of a rounded surface
function fx.highlight(p: GuiObject, r: number?): Frame
	local hi = Instance.new("Frame"); hi.Name = "Hi"; hi.BorderSizePixel = 0
	hi.BackgroundColor3 = T.color.text; hi.BackgroundTransparency = 0.86
	hi.Size = UDim2.new(1, 0, 0.42, 0); hi.ZIndex = p.ZIndex
	fx.corner(hi, r or T.radius.lg); hi.Parent = p
	fx.gradient(hi, nil, 90, NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1) }))
	return hi
end
UI.fx = fx

-- ===================================== layout helpers =======================================
local layout = {}
function layout.pad(p: Instance, n: number?): UIPadding
	local u = Instance.new("UIPadding"); n = n or T.space.md
	u.PaddingTop = UDim.new(0, n); u.PaddingBottom = UDim.new(0, n); u.PaddingLeft = UDim.new(0, n); u.PaddingRight = UDim.new(0, n); u.Parent = p; return u
end
function layout.list(p: Instance, horizontal: boolean?, gap: number?, halign: any?, valign: any?): UIListLayout
	local l = Instance.new("UIListLayout"); l.FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	l.Padding = UDim.new(0, gap or T.space.sm); l.SortOrder = Enum.SortOrder.LayoutOrder
	l.HorizontalAlignment = halign or Enum.HorizontalAlignment.Center; l.VerticalAlignment = valign or Enum.VerticalAlignment.Center; l.Parent = p; return l
end
function layout.grid(p: Instance, cell: UDim2, gap: number?): UIGridLayout
	local g = Instance.new("UIGridLayout"); g.CellSize = cell; g.CellPadding = UDim2.fromOffset(gap or T.space.sm, gap or T.space.sm)
	g.SortOrder = Enum.SortOrder.LayoutOrder; g.HorizontalAlignment = Enum.HorizontalAlignment.Center; g.Parent = p; return g
end
function layout.aspect(p: Instance, ratio: number): UIAspectRatioConstraint
	local a = Instance.new("UIAspectRatioConstraint"); a.AspectRatio = ratio; a.Parent = p; return a
end
function layout.scaleToViewport(p: Instance, baseY: number): UIScale
	local s = Instance.new("UIScale"); s.Parent = p
	local cam = workspace.CurrentCamera
	local function upd() if cam then s.Scale = math.clamp(cam.ViewportSize.Y / baseY, 0.7, 1.25) end end
	if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(upd) end; upd(); return s
end
UI.layout = layout

-- ======================================= motion =============================================
local motion = {}
function motion.tween(inst: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local t = TweenService:Create(inst, info, goal); t:Play(); return t
end
function motion.pop(inst: GuiObject, from: number?) -- spring scale-in
	local target = inst.Size
	inst.Size = UDim2.new(target.X.Scale * (from or 0.85), target.X.Offset * (from or 0.85), target.Y.Scale * (from or 0.85), target.Y.Offset * (from or 0.85))
	motion.tween(inst, T.motion.spring, { Size = target })
end
function motion.hoverGrow(btn: GuiObject, by: number?)
	local base = btn.Size; local grow = by or 6
	btn.MouseEnter:Connect(function() motion.tween(btn, T.motion.fast, { Size = base + UDim2.fromOffset(grow, grow * 0.66) }) end)
	btn.MouseLeave:Connect(function() motion.tween(btn, T.motion.fast, { Size = base }) end)
end
function motion.pulse(inst: GuiObject, prop: string, a: number, b: number)
	(inst :: any)[prop] = a; motion.tween(inst, T.motion.pulse, { [prop] = b })
end
-- moving shine sweep across a surface (a diagonal light bar that loops)
function motion.shine(surface: GuiObject, color: Color3?)
	local sh = Instance.new("Frame"); sh.BackgroundColor3 = color or Color3.new(1, 1, 1); sh.BorderSizePixel = 0
	sh.BackgroundTransparency = 0.75; sh.Size = UDim2.new(0.25, 0, 1.6, 0); sh.Rotation = 18
	sh.AnchorPoint = Vector2.new(0.5, 0.5); sh.Position = UDim2.fromScale(-0.3, 0.5); sh.ZIndex = surface.ZIndex + 3
	fx.gradient(sh, nil, 0, NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.4), NumberSequenceKeypoint.new(1, 1) }))
	sh.Parent = surface
	local clip = surface :: any; pcall(function() clip.ClipsDescendants = true end)
	task.spawn(function()
		while sh.Parent do
			sh.Position = UDim2.fromScale(-0.3, 0.5)
			motion.tween(sh, TweenInfo.new(0.9, Enum.EasingStyle.Quad), { Position = UDim2.fromScale(1.3, 0.5) })
			task.wait(3.2)
		end
	end)
	return sh
end
UI.motion = motion

-- ================================ State — tiny reactivity ===================================
local State = {}
State.__index = State
function UI.State(value: any)
	return setmetatable({ _v = value, _subs = {} }, State)
end
function State.get(self) return self._v end
function State.set(self, v) if v == self._v then return end self._v = v for _, fn in self._subs do fn(v) end end
function State.subscribe(self, fn) table.insert(self._subs, fn); fn(self._v); return function() end end
-- bind a State to a TextLabel's Text (optionally via a formatter)
function State.bindText(self, label: TextLabel, fmt: ((any) -> string)?)
	self:subscribe(function(v) label.Text = fmt and fmt(v) or tostring(v) end)
end

-- ==================================== COMPONENTS ============================================
local C = {}
-- Panel: the base raised surface = shadow + gradient fill + rim/hairline + highlight sheen
function C.Panel(props: { [string]: any }?): Frame
	props = props or {}
	local f = Instance.new("Frame"); f.Name = props.name or "Panel"; f.BorderSizePixel = 0
	f.BackgroundColor3 = props.fill or T.color.surface
	if props.size then f.Size = props.size end; if props.pos then f.Position = props.pos end
	if props.anchor then f.AnchorPoint = props.anchor end
	f.ZIndex = props.z or T.z.raised
	local r = props.radius or T.radius.lg
	fx.corner(f, r)
	fx.gradient(f, props.grad or ColorSequence.new(props.fill or T.color.surfaceHi, props.fill2 or T.color.deep), 90)
	if props.shadow ~= false then fx.shadow(f, props.shadow or "md") end
	if props.glow then fx.glow(f, role(props.glow)) end
	if props.accent then fx.rim(f, props.accent, props.rimTh) else fx.stroke(f, T.color.hairline, T.stroke.thin, 0.35) end
	if props.highlight ~= false then fx.highlight(f, r) end
	if props.parent then f.Parent = props.parent end
	return f
end
-- Pill: rounded stat chip = icon glyph + value, laid out
function C.Pill(props: { [string]: any }?): (Frame, TextLabel)
	props = props or {}
	local p = C.Panel({ name = props.name or "Pill", parent = props.parent, size = props.size or UDim2.fromOffset(120, 44), pos = props.pos,
		anchor = props.anchor, radius = T.radius.pill, fill = T.color.surface, shadow = "sm", z = props.z or T.z.hud + 1, accent = props.accent })
	-- lay out in an INNER content frame so the Panel's highlight is not swept into the list
	local content = Instance.new("Frame"); content.Name = "Content"; content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1); content.ZIndex = p.ZIndex + 1; content.Parent = p
	layout.pad(content, T.space.sm); layout.list(content, true, T.space.sm)
	if props.icon then
		local ic = Instance.new("TextLabel"); ic.BackgroundTransparency = 1; ic.Font = T.font.heading
		ic.Text = props.icon; ic.TextSize = props.iconSize or T.tsize.lg; ic.TextColor3 = props.iconColor or role(props.accent)
		ic.Size = UDim2.fromOffset(props.iconSize or 22, p.Size.Y.Offset - 12); ic.LayoutOrder = 1; ic.ZIndex = content.ZIndex + 1; ic.Parent = content
	end
	local v = Instance.new("TextLabel"); v.Name = "Value"; v.BackgroundTransparency = 1; v.Font = T.font.display
	v.Text = props.value or ""; v.TextSize = props.valueSize or T.tsize.xl; v.TextColor3 = props.valueColor or T.color.text
	v.AutomaticSize = Enum.AutomaticSize.X; v.Size = UDim2.new(0, 0, 1, 0); v.LayoutOrder = 2; v.ZIndex = content.ZIndex + 1
	v.TextXAlignment = Enum.TextXAlignment.Right; v.Parent = content
	return p, v
end
-- Badge: tiny number/level chip
function C.Badge(parent: Instance, txt: any, accent: any?): (Frame, TextLabel)
	local b = C.Panel({ name = "Badge", parent = parent, size = UDim2.fromOffset(26, 26), radius = T.radius.pill,
		fill = role(accent), fill2 = role(accent), shadow = "sm", highlight = false, z = ((parent :: any).ZIndex or 10) + 6 })
	local t = Instance.new("TextLabel"); t.BackgroundTransparency = 1; t.Font = T.font.heading; t.Text = tostring(txt)
	t.TextSize = T.tsize.sm; t.TextColor3 = T.color.textOnAccent; t.Size = UDim2.fromScale(1, 1); t.ZIndex = b.ZIndex + 1; t.Parent = b
	return b, t
end
-- IconChip: a rounded tinted square holding a glyph (the "icon on a chip" premium look)
function C.IconChip(props: { [string]: any }?): (Frame, TextLabel)
	props = props or {}
	local chip = C.Panel({ name = props.name or "IconChip", parent = props.parent, size = props.size or UDim2.fromOffset(56, 56),
		pos = props.pos, anchor = props.anchor, radius = props.radius or T.radius.lg, fill = props.fill or T.color.surfaceLo,
		fill2 = T.color.ink, accent = props.accent, glow = props.glow, z = props.z })
	local g = Instance.new("TextLabel"); g.BackgroundTransparency = 1; g.Font = props.font or T.font.display
	g.Text = props.glyph or "?"; g.TextSize = props.glyphSize or T.tsize.xxl; g.TextColor3 = props.glyphColor or role(props.accent)
	g.Size = UDim2.fromScale(1, 1); g.ZIndex = chip.ZIndex + 2; g.Parent = chip
	fx.textOutline(g, T.color.ink, 2)
	return chip, g
end
-- Button: CTA with gradient, rim, shadow, hover/press pop
function C.Button(props: { [string]: any }?): (TextButton, TextLabel)
	props = props or {}
	local accent = role(props.accent or "primary")
	local b = Instance.new("TextButton"); b.Name = props.name or "Button"; b.BorderSizePixel = 0; b.AutoButtonColor = false
	b.BackgroundColor3 = accent; b.Text = ""; b.Size = props.size or UDim2.fromOffset(200, 48)
	if props.pos then b.Position = props.pos end; if props.anchor then b.AnchorPoint = props.anchor end
	b.ZIndex = props.z or T.z.raised
	fx.corner(b, props.radius or T.radius.md)
	fx.gradient(b, ColorSequence.new(accent:Lerp(Color3.new(1, 1, 1), 0.3), accent), 90)
	fx.shadow(b, "md"); fx.rim(b, accent:Lerp(Color3.new(1, 1, 1), 0.55), T.stroke.thin); fx.highlight(b, props.radius or T.radius.md)
	local lbl = Instance.new("TextLabel"); lbl.BackgroundTransparency = 1; lbl.Font = T.font.heading; lbl.Text = props.text or "OK"
	lbl.TextSize = props.textSize or T.tsize.lg; lbl.TextColor3 = props.textColor or T.color.textOnAccent; lbl.Size = UDim2.fromScale(1, 1)
	lbl.ZIndex = b.ZIndex + 2; lbl.Parent = b
	if props.outline ~= false then fx.textOutline(lbl, T.color.ink, 2) end
	motion.hoverGrow(b, 6)
	b.MouseButton1Down:Connect(function() motion.tween(b, T.motion.fast, { Size = (props.size or UDim2.fromOffset(200, 48)) - UDim2.fromOffset(4, 3) }) end)
	if props.parent then b.Parent = props.parent end
	return b, lbl
end
-- StatBar: label + track + gradient fill (:Set(frac) later by caller via the returned fill)
function C.StatBar(props: { [string]: any }?): (Frame, Frame)
	props = props or {}
	local wrap = Instance.new("Frame"); wrap.Name = props.name or "Stat"; wrap.BackgroundTransparency = 1
	wrap.Size = props.size or UDim2.new(1, 0, 0, 30); wrap.ZIndex = props.z or T.z.raised
	if props.pos then wrap.Position = props.pos end; if props.anchor then wrap.AnchorPoint = props.anchor end
	if props.label then
		local lb = Instance.new("TextLabel"); lb.BackgroundTransparency = 1; lb.Font = T.font.body; lb.Text = props.label
		lb.TextSize = T.tsize.xs; lb.TextColor3 = T.color.textDim; lb.TextXAlignment = Enum.TextXAlignment.Left
		lb.Size = UDim2.new(1, 0, 0, 14); lb.ZIndex = wrap.ZIndex + 1; lb.Parent = wrap
	end
	local h = props.h or 10
	local track = C.Panel({ name = "Track", parent = wrap, size = UDim2.new(1, 0, 0, h), pos = UDim2.new(0, 0, 1, -h),
		anchor = Vector2.new(0, 1), radius = T.radius.pill, fill = T.color.surfaceLo, fill2 = T.color.ink, shadow = false, highlight = false, z = wrap.ZIndex })
	fx.stroke(track, T.color.ink, 1, 0.4)
	local fillCol = role(props.accent or "primary")
	local fill = Instance.new("Frame"); fill.Name = "Fill"; fill.BorderSizePixel = 0; fill.BackgroundColor3 = fillCol
	fill.Size = UDim2.new(math.clamp(props.value or 1, 0, 1), 0, 1, 0); fill.ZIndex = track.ZIndex + 1
	fx.corner(fill, T.radius.pill); fx.gradient(fill, ColorSequence.new(fillCol:Lerp(Color3.new(1, 1, 1), 0.35), fillCol), 90); fill.Parent = track
	if props.valueText then
		local vt = Instance.new("TextLabel"); vt.BackgroundTransparency = 1; vt.Font = T.font.heading; vt.Text = props.valueText
		vt.TextSize = T.tsize.xs; vt.TextColor3 = fillCol; vt.TextXAlignment = Enum.TextXAlignment.Right; vt.Size = UDim2.new(1, 0, 0, 14)
		vt.ZIndex = wrap.ZIndex + 2; vt.Parent = wrap
	end
	if props.parent then wrap.Parent = props.parent end
	return wrap, fill
end
-- Divider: a thin gradient rule
function C.Divider(parent: Instance, z: number?): Frame
	local d = Instance.new("Frame"); d.BorderSizePixel = 0; d.BackgroundColor3 = T.color.hairline; d.BackgroundTransparency = 0.5
	d.Size = UDim2.new(1, 0, 0, 1); d.ZIndex = z or T.z.raised
	fx.gradient(d, nil, 0, NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 1) }))
	d.Parent = parent; return d
end
-- Card: header(icon+title+subtitle+badge)/body/footer slots, full premium stack
function C.Card(props: { [string]: any }?): { root: Frame, header: Frame, body: Frame, footer: Frame }
	props = props or {}
	local root = C.Panel({ name = props.name or "Card", size = props.size or UDim2.fromOffset(240, 300), pos = props.pos,
		anchor = props.anchor or Vector2.new(0.5, 0.5), radius = T.radius.xl, fill = T.color.raised, fill2 = T.color.deep,
		shadow = props.shadow or "lg", accent = props.accent or "primary", glow = props.glow, z = props.z or T.z.raised })
	-- inner content frame so the Panel highlight is not swept into the header/body/footer list
	local content = Instance.new("Frame"); content.Name = "Content"; content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1); content.ZIndex = root.ZIndex + 1; content.Parent = root
	layout.pad(content, T.space.md); layout.list(content, false, T.space.sm, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local header = Instance.new("Frame"); header.Name = "Header"; header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, props.title and 44 or 0); header.ZIndex = content.ZIndex + 1; header.LayoutOrder = 1; header.Parent = content
	if props.title then
		local t = Instance.new("TextLabel"); t.BackgroundTransparency = 1; t.Font = T.font.display; t.Text = props.title
		t.TextSize = T.tsize.lg; t.TextColor3 = role(props.accent); t.TextXAlignment = Enum.TextXAlignment.Center
		t.Size = UDim2.new(1, 0, 1, 0); t.ZIndex = header.ZIndex + 1; t.Parent = header
	end
	local body = Instance.new("Frame"); body.Name = "Body"; body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 1, -((props.title and 44 or 0) + 48)); body.ZIndex = content.ZIndex + 1; body.LayoutOrder = 2; body.Parent = content
	layout.list(body, false, T.space.sm, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local footer = Instance.new("Frame"); footer.Name = "Footer"; footer.BackgroundTransparency = 1
	footer.Size = UDim2.new(1, 0, 0, 44); footer.ZIndex = content.ZIndex + 1; footer.LayoutOrder = 3; footer.Parent = content
	if props.parent then root.Parent = props.parent end
	if props.pop ~= false then motion.pop(root) end
	return { root = root, header = header, body = body, footer = footer }
end
-- Modal: dim scrim + spring-in Card. Returns { scrim, card } ; :close via caller Destroy(scrim)
function C.Modal(props: { [string]: any }?): { scrim: Frame, card: { root: Frame, header: Frame, body: Frame, footer: Frame } }
	props = props or {}
	local scrim = Instance.new("Frame"); scrim.Name = "Scrim"; scrim.BorderSizePixel = 0; scrim.BackgroundColor3 = T.color.overlay
	scrim.BackgroundTransparency = 1; scrim.Size = UDim2.fromScale(1, 1); scrim.ZIndex = T.z.modal
	if props.parent then scrim.Parent = props.parent end
	motion.tween(scrim, T.motion.base, { BackgroundTransparency = 0.35 })
	local card = C.Card({ parent = scrim, size = props.size or UDim2.fromOffset(360, 420), title = props.title,
		accent = props.accent, glow = props.accent, z = T.z.modal + 1 })
	return { scrim = scrim, card = card }
end
UI.Components = C
-- flatten components onto UI for terse access (UI.Panel, UI.Button, ...)
for name, fn in C do UI[name] = fn end

return UI
