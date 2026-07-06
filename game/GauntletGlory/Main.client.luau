--!strict
-- NEON GAUNTLET // 無限刃 — an infinite, anime, Bloons-deep GUI tower defense.
-- You summon shonen "fighters" onto a curving neon battle-street, forge a CLASS across a roguelite
-- draft, and hold the line forever against escalating waves + NPC BOSSES that SMASH your fighters
-- off the board. Pure GUI (no meshes/parts). ONE Heartbeat drives everything; all FX pooled.
-- Anime feel = ink+neon cel-shaded panels, bold outlines, slanted shonen text, and heavy impact FX
-- (hit-stop, crit numbers, slash flashes, hit sparks, screen shake/flash, boss intro cards).

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

local DEBUG = { autoPlay = false, forceBossWave = 0, rich = false }

-- ===== Palette (ink base so neon POPS) =====
local C = {
	ink = Color3.fromRGB(11, 14, 20),
	ink2 = Color3.fromRGB(17, 21, 30),
	panel = Color3.fromRGB(24, 29, 42),
	panelHi = Color3.fromRGB(40, 48, 66),
	cyan = Color3.fromRGB(53, 230, 255),
	magenta = Color3.fromRGB(255, 77, 157),
	gold = Color3.fromRGB(255, 209, 92),
	lime = Color3.fromRGB(170, 255, 120),
	violet = Color3.fromRGB(168, 120, 255),
	red = Color3.fromRGB(255, 76, 96),
	white = Color3.fromRGB(245, 249, 255),
	dim = Color3.fromRGB(120, 132, 155),
	ink0 = Color3.fromRGB(6, 8, 12),
	core = Color3.fromRGB(90, 240, 200),
}
-- grounded diorama additions (kept out of the literal so the element colors above stay obvious)
C.asphalt    = Color3.fromRGB(74, 76, 86)    -- lit road, reads as a dark path on warm earth
C.asphaltD   = Color3.fromRGB(50, 52, 60)
C.roadEdge   = Color3.fromRGB(176, 158, 120)  -- bright warm stone curb (catches dusk light)
C.lanePaint  = Color3.fromRGB(236, 229, 206)
C.roadShadow = Color3.fromRGB(12, 12, 16)
C.groundTop  = Color3.fromRGB(150, 144, 130)  -- cleaner warm-STONE tabletop (less muddy brown => colors pop)
C.groundBot  = Color3.fromRGB(84, 80, 74)     -- warm dark stone near the rim
C.pad        = Color3.fromRGB(158, 148, 128)  -- lit warm stone foundation under a placed tower
C.groundEdge = Color3.fromRGB(150, 132, 104)  -- warm stone rim of the tabletop
C.skyTop     = Color3.fromRGB(44, 50, 92)     -- deep dusk indigo (now visible)
C.skyBot     = Color3.fromRGB(168, 104, 90)   -- warm sunset horizon
C.silhouette = Color3.fromRGB(36, 36, 54)     -- distant hills/pagodas read against the dusk
local FONT = Enum.Font.GothamBlack
local FONT2 = Enum.Font.GothamBold

-- ===== styled helpers (cel + ink outline is the "anime line-art" trick) =====
local function corner(p: Instance, r: number)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = p; return c
end
local function stroke(p: Instance, col: Color3, th: number, tr: number?)
	local s = Instance.new("UIStroke"); s.Color = col; s.Thickness = th; s.Transparency = tr or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; s.Parent = p; return s
end
local function frame(parent: Instance, name: string?): Frame
	local f = Instance.new("Frame"); f.Name = name or "F"; f.BorderSizePixel = 0
	f.BackgroundColor3 = C.panel; f.Parent = parent; return f
end
-- a cel-shaded panel: fill + hard ink outline + a top highlight wedge (2-tone anime shading)
local function cel(parent: Instance, col: Color3, r: number, outline: number?): Frame
	local f = frame(parent)
	f.BackgroundColor3 = col
	corner(f, r)
	stroke(f, C.ink0, outline or 3, 0)
	local hi = frame(f, "Hi")
	hi.BackgroundColor3 = C.white
	hi.BackgroundTransparency = 0.82
	hi.Size = UDim2.new(1, 0, 0.42, 0)
	hi.Position = UDim2.fromScale(0, 0)
	hi.ZIndex = (f.ZIndex or 1)
	corner(hi, r)
	return f
end
local function text(parent: Instance, s: string, size: number, col: Color3?): TextLabel
	local t = Instance.new("TextLabel"); t.BackgroundTransparency = 1; t.Font = FONT2
	t.Text = s; t.TextSize = size; t.TextColor3 = col or C.white; t.Parent = parent; return t
end
-- slanted shonen headline: rotated + fat black ink outline (the shonen title look)
local function shout(parent: Instance, s: string, size: number, col: Color3): TextLabel
	local t = text(parent, s, size, col)
	t.Font = FONT; t.Rotation = -6
	stroke(t, C.ink0, math.max(2, size / 9), 0)
	return t
end
local function button(parent: Instance): TextButton
	local b = Instance.new("TextButton"); b.BackgroundTransparency = 1; b.Text = ""
	b.AutoButtonColor = false; b.Size = UDim2.fromScale(1, 1); b.Parent = parent; return b
end

-- ===== root =====
local gui = Instance.new("ScreenGui")
gui.Name = "NeonGauntlet"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 60; gui.Parent = pg

local root = frame(gui, "Root") -- shaken as a whole for screen-shake
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = C.ink
local bgGrad = Instance.new("UIGradient")
bgGrad.Rotation = 90
bgGrad.Color = ColorSequence.new(Color3.fromRGB(16, 20, 30), Color3.fromRGB(8, 9, 14))
bgGrad.Parent = root
-- faint diagonal ink hatch vibe via two tinted bars
for i = 0, 1 do
	local streak = frame(root, "Streak")
	streak.BackgroundColor3 = i == 0 and C.cyan or C.magenta
	streak.BackgroundTransparency = 0.985 -- dialed down: dusk sky dominates, not neon hatch
	streak.Size = UDim2.fromScale(1.4, 0.06)
	streak.Rotation = -18
	streak.Position = UDim2.fromScale(-0.2, i == 0 and 0.2 or 0.75)
end

local fxLayer = frame(root, "FX"); fxLayer.BackgroundTransparency = 1; fxLayer.Size = UDim2.fromScale(1, 1); fxLayer.ZIndex = 40

-- ===== global time-scale (hit-stop) =====
local timeScale = 1.0
local function hitStop(dur: number)
	timeScale = 0.0
	task.delay(dur, function() timeScale = 1.0 end)
end

-- ===== track (curving neon battle-street via waypoints) =====
local WAYPOINTS = {
	Vector2.new(0.5, 0.06), Vector2.new(0.78, 0.16), Vector2.new(0.80, 0.40),
	Vector2.new(0.55, 0.50), Vector2.new(0.22, 0.44), Vector2.new(0.20, 0.68),
	Vector2.new(0.45, 0.80), Vector2.new(0.72, 0.82), Vector2.new(0.5, 0.94),
}
-- ===== dusk environment backdrop (pure Frames, sits BEHIND the board) =====
local function buildBackdrop()
	local sky = frame(root, "Sky")
	sky.AnchorPoint = Vector2.new(0.5, 0.5); sky.Position = UDim2.fromScale(0.5, 0.5)
	sky.Size = UDim2.fromScale(1, 1); sky.BackgroundColor3 = C.skyBot; sky.ZIndex = 1
	local sg = Instance.new("UIGradient"); sg.Rotation = 90
	sg.Color = ColorSequence.new(C.skyTop, C.skyBot); sg.Parent = sky
	local horizon = 0.66
	local shapes = {
		{ x = 0.16, w = 0.30, h = 0.10 }, { x = 0.83, w = 0.34, h = 0.12 },
		{ x = 0.30, w = 0.05, h = 0.16 }, { x = 0.70, w = 0.045, h = 0.14 },
		{ x = 0.50, w = 0.22, h = 0.07 },
	}
	for _, s in shapes do
		local hill = frame(sky, "Silhouette"); hill.AnchorPoint = Vector2.new(0.5, 1)
		hill.Position = UDim2.fromScale(s.x, horizon + s.h * 0.5); hill.Size = UDim2.fromScale(s.w, s.h)
		hill.BackgroundColor3 = C.silhouette; hill.ZIndex = 1; corner(hill, 10)
	end
	for _, x in { 0.30, 0.70 } do
		local cap = frame(sky, "Cap"); cap.AnchorPoint = Vector2.new(0.5, 1)
		cap.Position = UDim2.fromScale(x, horizon - 0.06); cap.Size = UDim2.fromScale(0.035, 0.035)
		cap.BackgroundColor3 = C.silhouette; cap.Rotation = 45; cap.ZIndex = 1
	end
end
buildBackdrop()

local board = frame(root, "Board")
board.BackgroundColor3 = C.groundBot
board.AnchorPoint = Vector2.new(0.5, 0.5)
board.Position = UDim2.fromScale(0.5, 0.53)
board.Size = UDim2.fromScale(0.62, 0.88)
board.ZIndex = 2
do
	local gg = Instance.new("UIGradient"); gg.Rotation = 90
	gg.Color = ColorSequence.new(C.groundTop, C.groundBot); gg.Parent = board
	corner(board, 18); stroke(board, C.groundEdge, 4, 0)
end
-- foreground VIGNETTE: darken the top/bottom edges to funnel the eye inward (cheap cinematic depth).
-- A plain Frame (not Active, not a button) does not intercept clicks to the nodes below it.
local vign = frame(root, "Vignette"); vign.Size = UDim2.fromScale(1, 1)
vign.BackgroundColor3 = Color3.new(0, 0, 0); vign.BackgroundTransparency = 0; vign.ZIndex = 25
do
	local vg = Instance.new("UIGradient"); vg.Rotation = 90
	vg.Color = ColorSequence.new(Color3.new(0, 0, 0))
	vg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.28, 1),
		NumberSequenceKeypoint.new(0.72, 1), NumberSequenceKeypoint.new(1, 0.25),
	})
	vg.Parent = vign
end
-- (the road is drawn as a solid ribbon AFTER pathPos is defined — see drawRoad below)
-- helper: world (scale) position of progress p in [0,1] along the waypoint path
local segLens = {}
local totalLen = 0
for i = 1, #WAYPOINTS - 1 do
	local l = (WAYPOINTS[i + 1] - WAYPOINTS[i]).Magnitude
	segLens[i] = l; totalLen += l
end
local function pathPos(p: number): Vector2
	p = math.clamp(p, 0, 1)
	local target = p * totalLen
	local acc = 0
	for i = 1, #WAYPOINTS - 1 do
		if acc + segLens[i] >= target then
			local t = (target - acc) / segLens[i]
			return WAYPOINTS[i]:Lerp(WAYPOINTS[i + 1], t)
		end
		acc += segLens[i]
	end
	return WAYPOINTS[#WAYPOINTS]
end

-- ===== solid-ribbon road (capsule chain: gap-free at every bend) =====
local ROAD = { W = 30 } -- road width in px (constant); lengths stay board-SCALE
local function ribbonSeg(a: Vector2, b: Vector2, wpx: number, col: Color3, z: number): Frame
	local mid = (a + b) / 2
	local d = b - a
	local seg = frame(board, "RSeg")
	seg.AnchorPoint = Vector2.new(0.5, 0.5)
	seg.Position = UDim2.fromScale(mid.X, mid.Y)
	seg.Size = UDim2.new(d.Magnitude, 0, 0, wpx) -- length SCALE, width PX
	seg.BackgroundColor3 = col
	seg.Rotation = math.deg(math.atan2(d.Y, d.X))
	seg.ZIndex = z
	return seg
end
local function ribbonJoint(p: Vector2, wpx: number, col: Color3, z: number): Frame
	local j = frame(board, "RJoint")
	j.AnchorPoint = Vector2.new(0.5, 0.5)
	j.Position = UDim2.fromScale(p.X, p.Y)
	j.Size = UDim2.new(0, wpx, 0, wpx)
	j.BackgroundColor3 = col
	j.ZIndex = z
	corner(j, math.floor(wpx / 2)) -- full radius => circle welds the joint
	return j
end
local function chain(wpx: number, col: Color3, z: number, off: number?): { Frame }
	local pieces = {}
	local function nudge(inst: Frame)
		if off then
			local p = inst.Position
			inst.Position = UDim2.new(p.X.Scale, off, p.Y.Scale, off)
		end
	end
	for i = 1, #WAYPOINTS - 1 do
		local s = ribbonSeg(WAYPOINTS[i], WAYPOINTS[i + 1], wpx, col, z); nudge(s); table.insert(pieces, s)
	end
	for i = 1, #WAYPOINTS do
		local j = ribbonJoint(WAYPOINTS[i], wpx, col, z); nudge(j); table.insert(pieces, j)
	end
	return pieces
end
local function drawRoad()
	-- LAYER 1 (Z2): drop shadow — wider, darker, nudged down so the road sits on the ground
	for _, pc in chain(ROAD.W + 8, C.roadShadow, 2, 0.006) do
		pc.BackgroundTransparency = 0.15
	end
	-- LAYER 2+3 (Z3): asphalt body with top-lit gradient + continuous warm curb
	for _, pc in chain(ROAD.W, C.asphalt, 3) do
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Color = ColorSequence.new(C.asphalt, C.asphaltD)
		g.Parent = pc
		stroke(pc, C.roadEdge, 2, 0.15)
	end
	-- LAYER 4 (Z5): painted center dashes, sampled by arc length so spacing is even on curves
	local DASH, GAP = 0.016, 0.026
	local step = DASH + GAP
	local t = GAP * 0.5
	while t < 1 do
		local a = pathPos(t)
		local b = pathPos(math.min(1, t + DASH))
		local d = b - a
		if d.Magnitude > 0 then
			local mid = (a + b) / 2
			local dash = frame(board, "RDash")
			dash.AnchorPoint = Vector2.new(0.5, 0.5)
			dash.Position = UDim2.fromScale(mid.X, mid.Y)
			dash.Size = UDim2.new(d.Magnitude, 0, 0, 3)
			dash.BackgroundColor3 = C.lanePaint
			dash.BackgroundTransparency = 0.25
			dash.Rotation = math.deg(math.atan2(d.Y, d.X))
			dash.ZIndex = 5
			corner(dash, 2)
		end
		t += step
	end
end
drawRoad()

-- Core at the end of the track
local coreP = pathPos(1)
local coreNode = cel(board, C.core, 12)
coreNode.AnchorPoint = Vector2.new(0.5, 0.5)
coreNode.Position = UDim2.fromScale(coreP.X, coreP.Y)
coreNode.Size = UDim2.fromScale(0.12, 0.05)
coreNode.ZIndex = 7
text(coreNode, "\u{6838}", 20, C.ink0).Size = UDim2.fromScale(1, 1)

-- ===== fighter defs (element-colored, glyph, one upgrade path for now) =====
type Def = { id: string, name: string, color: Color3, glyph: string, element: string,
	dmg: number, rate: number, range: number, cost: number, slow: number, kind: string }
local FIGHTERS: { [string]: Def } = {
	Ronin = { id = "Ronin", name = "Ronin", color = C.cyan, glyph = "\u{5203}", element = "Blade",
		dmg = 14, rate = 0.7, range = 0.16, cost = 18, slow = 0, kind = "slash" },
	Onmyoji = { id = "Onmyoji", name = "Frost Onmyoji", color = Color3.fromRGB(130, 220, 235), glyph = "\u{96EA}", element = "Cold",
		dmg = 8, rate = 0.85, range = 0.2, cost = 22, slow = 0.5, kind = "beam" },
	Archer = { id = "Archer", name = "Storm Archer", color = C.violet, glyph = "\u{5F13}", element = "Storm",
		dmg = 10, rate = 0.5, range = 0.24, cost = 20, slow = 0, kind = "bolt" },
	Monk = { id = "Monk", name = "War Monk", color = C.gold, glyph = "\u{62F3}", element = "Kinetic",
		dmg = 22, rate = 1.1, range = 0.15, cost = 24, slow = 0, kind = "impact" },
}
local START = "Ronin"
local ELEM_COLOR = { Blade = C.cyan, Cold = Color3.fromRGB(130, 220, 235), Storm = C.violet, Kinetic = C.gold }

-- ===== upgrade traits (the "class curation") =====
-- Each fighter has distinct named upgrades drafted between waves. Picking them shapes
-- a build — bloons-TD-style paths, not one flat "+dmg" button. Additive modifiers:
-- dmg/rate/range are +fractions; crit is +chance; critMul is +multiplier; slowAdd extends slow.
local TRAITS: { [string]: { any } } = {
	Ronin = {
		{ key = "bloodlust",   name = "Bloodlust",   tip = "+45% attack speed", rate = 0.45 },
		{ key = "executioner", name = "Executioner", tip = "+18% crit, crits x2.6", crit = 0.18, critMul = 0.6 },
		{ key = "longreach",   name = "Long Reach",  tip = "+40% range", range = 0.40 },
		{ key = "keenedge",    name = "Keen Edge",   tip = "+55% damage", dmg = 0.55 },
	},
	Onmyoji = {
		{ key = "deepfreeze",  name = "Deep Freeze", tip = "+50% stronger slow", slowAdd = 0.25 },
		{ key = "frostbite",   name = "Frostbite",   tip = "+60% damage", dmg = 0.60 },
		{ key = "gale",        name = "Gale",        tip = "+40% attack speed", rate = 0.40 },
		{ key = "glacier",     name = "Glacier",     tip = "+45% range", range = 0.45 },
	},
	Archer = {
		{ key = "volley",      name = "Volley",      tip = "+55% attack speed", rate = 0.55 },
		{ key = "piercer",     name = "Piercer",     tip = "+22% crit", crit = 0.22 },
		{ key = "farsight",    name = "Farsight",    tip = "+45% range", range = 0.45 },
		{ key = "broadhead",   name = "Broadhead",   tip = "+50% damage", dmg = 0.50 },
	},
	Monk = {
		{ key = "quake",       name = "Quake Palm",  tip = "+70% damage", dmg = 0.70 },
		{ key = "flurry",      name = "Flurry",      tip = "+50% attack speed", rate = 0.50 },
		{ key = "ironbody",    name = "Iron Body",   tip = "+35% range", range = 0.35 },
		{ key = "focus",       name = "Focus",       tip = "+16% crit, crits x2.5", crit = 0.16, critMul = 0.5 },
	},
}

-- ===== HUD =====
local hud = frame(root, "HUD"); hud.BackgroundTransparency = 1; hud.Size = UDim2.new(1, 0, 0, 64); hud.ZIndex = 30
local waveT = shout(hud, "WAVE 1", 26, C.cyan)
waveT.AnchorPoint = Vector2.new(0.5, 0); waveT.Position = UDim2.fromScale(0.5, 0.15); waveT.Size = UDim2.fromScale(0.5, 0.7)
waveT.ZIndex = 31
local yenT = text(hud, "\u{00A5} 40", 22, C.gold)
yenT.Font = FONT; yenT.AnchorPoint = Vector2.new(1, 0); yenT.Position = UDim2.new(1, -24, 0, 16); yenT.Size = UDim2.fromScale(0.2, 0.5)
yenT.TextXAlignment = Enum.TextXAlignment.Right; yenT.ZIndex = 31
-- core lives (hearts)
local lifeBox = frame(hud, "Lives"); lifeBox.BackgroundTransparency = 1; lifeBox.Position = UDim2.fromScale(0.02, 0.2); lifeBox.Size = UDim2.fromScale(0.2, 0.5); lifeBox.ZIndex = 31
local lifeText = text(lifeBox, "", 22, C.red); lifeText.Font = FONT; lifeText.Size = UDim2.fromScale(1, 1); lifeText.TextXAlignment = Enum.TextXAlignment.Left

-- class tray (your roster) down the left
local tray = frame(root, "Tray"); tray.BackgroundTransparency = 1; tray.AnchorPoint = Vector2.new(0, 0.5)
tray.Position = UDim2.fromScale(0.015, 0.55); tray.Size = UDim2.fromScale(0.1, 0.6); tray.ZIndex = 30
local tl = Instance.new("UIListLayout"); tl.Padding = UDim.new(0, 8); tl.HorizontalAlignment = Enum.HorizontalAlignment.Center
tl.SortOrder = Enum.SortOrder.LayoutOrder; tl.Parent = tray
local trayTitle = text(tray, "CLASS", 13, C.dim); trayTitle.Size = UDim2.new(1, 0, 0, 16); trayTitle.LayoutOrder = 0

-- ===== state =====
-- owned = summoned fighters; traits = the acquired upgrade keys per fighter (the "class");
-- upgrades = trait-count tier (drives the tray star pips); dmgByType = forge bookkeeping
local RunState = { owned = { [START] = true }, traits = { [START] = {} }, upgrades = { [START] = 0 }, dmgByType = { [START] = 0 } }
local state = { wave = 0, yen = 40, lives = 5, running = true, drafting = false,
	enemies = {} :: { any }, queue = {} :: { any }, towers = {} :: { any } }
local MAX_LIVE = 44

local function setYen(n: number) state.yen = n; yenT.Text = "\u{00A5} " .. n end
local function setLives(n: number) state.lives = math.max(0, n); lifeText.Text = string.rep("\u{2665}", state.lives) end
if DEBUG.rich then -- TEST: own all fighters + big bank so autoPlay fills the board with every model
	for _, id in { "Ronin", "Onmyoji", "Archer", "Monk" } do
		RunState.owned[id] = true; RunState.traits[id] = RunState.traits[id] or {}
		RunState.upgrades[id] = RunState.upgrades[id] or 0; RunState.dmgByType[id] = RunState.dmgByType[id] or 0
	end
	state.yen = 900; state.lives = 99
end
setYen(state.yen); setLives(state.lives)

local function refreshTray()
	for _, c in tray:GetChildren() do if c:IsA("Frame") then c:Destroy() end end
	local i = 1
	for id in RunState.owned do
		local def = FIGHTERS[id]
		local chip = cel(tray, def.color, 10)
		chip.Size = UDim2.new(0, 46, 0, 46); chip.LayoutOrder = i; chip.ZIndex = 30
		local g = text(chip, def.glyph, 22, C.ink0); g.Font = FONT; g.Size = UDim2.fromScale(1, 1); g.ZIndex = 31
		if (RunState.upgrades[id] or 0) > 0 then
			local pip = text(chip, string.rep("\u{2605}", RunState.upgrades[id]), 11, C.gold)
			pip.AnchorPoint = Vector2.new(0.5, 1); pip.Position = UDim2.fromScale(0.5, 1); pip.Size = UDim2.fromScale(1, 0.3); pip.ZIndex = 32
		end
		i += 1
	end
end
refreshTray()

-- ===== FX (pooled-ish; capped) =====
local critCount = 0
local function critNumber(px: number, py: number, val: number, crit: boolean, col: Color3)
	if critCount > 26 then return end
	critCount += 1
	local l = text(fxLayer, val .. (crit and "!!" or ""), crit and 34 or 22, crit and C.gold or col)
	l.Font = FONT; l.Rotation = crit and math.random(-12, 12) or -6
	stroke(l, C.ink0, crit and 3 or 2, 0)
	l.AnchorPoint = Vector2.new(0.5, 0.5); l.Position = UDim2.fromScale(px, py)
	l.ZIndex = 45
	l.TextScaled = true -- so the size-punch actually scales the number
	-- punch scale via TextSize tween proxy (use Size scale)
	local endSize = crit and UDim2.fromScale(0.11, 0.05) or UDim2.fromScale(0.07, 0.032)
	l.Size = UDim2.fromScale(0.02, 0.01)
	TweenService:Create(l, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = endSize }):Play()
	TweenService:Create(l, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(px + (math.random() - 0.5) * 0.04, py - 0.06), TextTransparency = 1 }):Play()
	task.delay(0.45, function() l:Destroy(); critCount -= 1 end)
end
local sparkCount = 0
local function hitSpark(px: number, py: number, col: Color3)
	if sparkCount > 30 then return end
	for _ = 1, 5 do
		sparkCount += 1
		local s = frame(fxLayer, "Spark")
		s.BackgroundColor3 = col; s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Position = UDim2.fromScale(px, py); s.Size = UDim2.fromScale(0.012, 0.006)
		s.Rotation = math.random(0, 360); s.ZIndex = 44
		corner(s, 2)
		local ang = math.rad(math.random(0, 360)); local dist = 0.03 + math.random() * 0.03
		TweenService:Create(s, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(px + math.cos(ang) * dist, py + math.sin(ang) * dist),
			BackgroundTransparency = 1 }):Play()
		task.delay(0.22, function() s:Destroy(); sparkCount -= 1 end)
	end
end
local function slashFlash(px: number, py: number, col: Color3)
	local f = frame(fxLayer, "Slash")
	f.BackgroundColor3 = C.white; f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(px, py); f.Size = UDim2.fromScale(0.14, 0.01)
	f.Rotation = math.random(20, 50); f.ZIndex = 43
	corner(f, 2)
	TweenService:Create(f, TweenInfo.new(0.12), { BackgroundTransparency = 1, Size = UDim2.fromScale(0.2, 0.002) }):Play()
	task.delay(0.13, function() f:Destroy() end)
end
local function screenShake(mag: number, frames: number)
	task.spawn(function()
		for _ = 1, frames do
			root.Position = UDim2.fromOffset(math.random(-mag, mag), math.random(-mag, mag))
			task.wait(0.02)
		end
		root.Position = UDim2.fromScale(0, 0)
	end)
end
local function screenFlash(col: Color3, alpha: number)
	local f = frame(fxLayer, "Flash"); f.Size = UDim2.fromScale(1, 1); f.BackgroundColor3 = col
	f.BackgroundTransparency = alpha; f.ZIndex = 48
	TweenService:Create(f, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	task.delay(0.36, function() f:Destroy() end)
end
local function speedLines()
	for _ = 1, 12 do
		local s = frame(fxLayer, "SL"); s.BackgroundColor3 = C.white; s.BackgroundTransparency = 0.2
		local ang = math.random(0, 360); local r = 0.6
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Position = UDim2.fromScale(0.5 + math.cos(math.rad(ang)) * r, 0.5 + math.sin(math.rad(ang)) * r * 0.6)
		s.Size = UDim2.fromScale(0.16, 0.004); s.Rotation = ang; s.ZIndex = 47
		TweenService:Create(s, TweenInfo.new(0.3), { Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1, Size = UDim2.fromScale(0.02, 0.002) }):Play()
		task.delay(0.32, function() s:Destroy() end)
	end
end
local function banner(s: string, col: Color3)
	local b = shout(fxLayer, s, 46, col)
	b.AnchorPoint = Vector2.new(0.5, 0.5); b.Position = UDim2.fromScale(0.5, 0.34); b.Size = UDim2.fromScale(0.8, 0.12)
	b.ZIndex = 46; b.TextTransparency = 0
	b.Size = UDim2.fromScale(0.5, 0.1)
	TweenService:Create(b, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.8, 0.12) }):Play()
	task.delay(0.9, function()
		TweenService:Create(b, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		task.delay(0.45, function() b:Destroy() end)
	end)
end

-- ===== enemy pool (anime tokens) =====
local function makeEnemy(): any
	local body = cel(board, C.magenta, 10, 2)
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Size = UDim2.fromScale(0.09, 0.05); body.Visible = false; body.ZIndex = 8
	-- two glowing eye slits
	for i = 0, 1 do
		local eye = frame(body, "Eye"); eye.BackgroundColor3 = C.white; eye.Size = UDim2.fromScale(0.16, 0.12)
		eye.Position = UDim2.fromScale(0.28 + i * 0.34, 0.32); eye.ZIndex = 10; corner(eye, 2)
	end
	local bar = frame(body, "HP"); bar.AnchorPoint = Vector2.new(0.5, 1); bar.Position = UDim2.fromScale(0.5, 1.34)
	bar.Size = UDim2.new(1, 0, 0, 4); bar.BackgroundColor3 = C.lime; bar.ZIndex = 11; corner(bar, 2)
	local barBg = frame(body, "HPbg"); barBg.AnchorPoint = Vector2.new(0.5, 1); barBg.Position = UDim2.fromScale(0.5, 1.34)
	barBg.Size = UDim2.new(1, 0, 0, 4); barBg.BackgroundColor3 = C.ink0; barBg.ZIndex = 10; corner(barBg, 2)
	bar.ZIndex = 11
	return { body = body, bar = bar, hp = 0, maxHp = 0, speed = 0, baseSpeed = 0, slowT = 0,
		progress = 0, active = false, dying = false, boss = false }
end
local pool = {}
for _ = 1, MAX_LIVE do table.insert(pool, makeEnemy()) end
local function acquire(): any?
	for _, e in pool do if not e.active and not e.dying then return e end end
	return nil
end
local function releaseEnemy(e: any)
	e.active = false; e.body.Visible = false
	local i = table.find(state.enemies, e); if i then table.remove(state.enemies, i) end
end

-- ===== waves =====
-- enemy archetypes — distinct color/size/HP/speed so a wave reads as a varied horde,
-- not a line of identical blobs. Mixed in by wave number below.
local ETYPES = {
	runner = { color = C.magenta, sizeMul = 1.0, hpMul = 1.0, spdMul = 1.0 },
	swift  = { color = C.lime,    sizeMul = 0.78, hpMul = 0.55, spdMul = 1.8 },
	brute  = { color = C.red,     sizeMul = 1.4,  hpMul = 3.4, spdMul = 0.68 },
}
local function schedule(n: number): { any }
	local count = 6 + math.floor(n * 1.5)
	local hp = 14 * (1.15 ^ n)
	local spd = 0.05 + math.min(n, 30) * 0.0015
	local swarm = (n % 10 == 0) -- every 10th wave = a fast swarm
	local list = {}
	for i = 1, count do
		local t = "runner"
		if swarm then t = "swift"
		elseif n >= 5 and i % 5 == 0 then t = "brute"
		elseif n >= 3 and i % 3 == 0 then t = "swift" end
		local et = ETYPES[t]
		table.insert(list, { hp = math.floor(hp * et.hpMul), speed = spd * et.spdMul, boss = false, etype = t })
	end
	return list
end
local function spawnOne(def: any)
	local e = acquire(); if not e then return end
	e.hp = def.hp; e.maxHp = def.hp; e.speed = def.speed; e.baseSpeed = def.speed
	e.slowT = 0; e.boss = def.boss or false; e.progress = 0; e.active = true
	local et = ETYPES[def.etype or "runner"]
	e.body.BackgroundColor3 = def.boss and C.red or et.color
	e.body.Size = def.boss and UDim2.fromScale(0.22, 0.13)
		or UDim2.fromScale(0.09 * et.sizeMul, 0.05 * et.sizeMul)
	e.bar.Size = UDim2.new(1, 0, 0, 4)
	e.body.Visible = true
	table.insert(state.enemies, e)
end

-- ===== fighters (towers) =====
local endRun -- fwd
local function fStats(id: string): any
	local def = FIGHTERS[id]
	local dmgMul, rateMul, rangeMul = 1, 1, 1
	local critC, critMul, slowAdd = 0.22, 2.0, 0
	local owned = RunState.traits[id] or {}
	for _, tr in TRAITS[id] or {} do
		if owned[tr.key] then
			dmgMul += (tr.dmg or 0); rateMul += (tr.rate or 0); rangeMul += (tr.range or 0)
			critC += (tr.crit or 0); critMul += (tr.critMul or 0); slowAdd += (tr.slowAdd or 0)
		end
	end
	return {
		dmg = def.dmg * dmgMul,
		rate = math.max(0.12, def.rate / rateMul),
		range = def.range * rangeMul,
		crit = math.min(0.85, critC),
		critMul = critMul,
		slow = def.slow > 0 and (def.slow + slowAdd) or 0,
	}
end
local function pxOf(p: Vector2): (number, number)
	-- board is 0.62x0.88 of screen centered at (0.5,0.53); convert board-scale to screen-scale
	return 0.5 + (p.X - 0.5) * 0.62, 0.53 + (p.Y - 0.5) * 0.88
end

local NODES = {} -- socket positions beside the track
do
	local spots = { Vector2.new(0.62, 0.30), Vector2.new(0.40, 0.30), Vector2.new(0.66, 0.55), Vector2.new(0.34, 0.55),
		Vector2.new(0.60, 0.72), Vector2.new(0.36, 0.72), Vector2.new(0.5, 0.20), Vector2.new(0.5, 0.64) }
	for _, s in spots do table.insert(NODES, s) end
end

local function damageEnemy(e: any, dmg: number, crit: boolean, id: string)
	e.hp -= dmg
	RunState.dmgByType[id] = (RunState.dmgByType[id] or 0) + dmg
	e.bar.Size = UDim2.new(math.clamp(e.hp / e.maxHp, 0, 1), 0, 0, 4)
	local sx, sy = pxOf(Vector2.new(pathPos(e.progress).X, pathPos(e.progress).Y))
	critNumber(sx, sy, dmg, crit, FIGHTERS[id].color)
	hitSpark(sx, sy, FIGHTERS[id].color)
	if crit then hitStop(0.06); screenShake(4, 3) end
	if e.hp <= 0 and e.active then
		local reward = e.boss and 120 or 5
		setYen(state.yen + reward)
		e.active = false; e.dying = true
		hitSpark(sx, sy, C.white)
		TweenService:Create(e.body, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Size = UDim2.fromScale(0.01, 0.01) }):Play()
		task.delay(0.16, function() e.body.Visible = false; e.dying = false; local i = table.find(state.enemies, e); if i then table.remove(state.enemies, i) end end)
		if e.boss then banner("BOSS SLAIN", C.gold); screenFlash(C.gold, 0.4); speedLines() end
	end
end

-- ===== 3D tower viewports (Parts only, no uploads) =====
local rad = math.rad
-- MODELS: id -> { accent, parts = { {shape,size,off, rotY?,tilt?, material,color, neon?,light?}, ... } }
local MODELS = {
	Ronin = { accent = C.cyan, parts = {
		{ "Block", Vector3.new(0.55,1.1,0.55), Vector3.new(-0.42,0.55,0), "Slate", Color3.fromRGB(32,34,46) }, -- left leg / greave (dark lacquer)
		{ "Block", Vector3.new(0.55,1.1,0.55), Vector3.new(0.42,0.55,0), "Slate", Color3.fromRGB(32,34,46) }, -- right leg / greave
		{ "Block", Vector3.new(1.5,1.5,0.9), Vector3.new(0,1.85,0), "Metal", Color3.fromRGB(38,46,84) }, -- torso / dou armor (indigo lacquered)  PrimaryPart
		{ "Block", Vector3.new(1.55,0.35,0.98), Vector3.new(0,1.2,0), "Fabric", Color3.fromRGB(20,22,30) }, -- kusazuri armor skirt hem (charcoal)  hides leg-torso sea
		{ "Block", Vector3.new(0.7,0.5,1.05), Vector3.new(-0.95,2.42,0), "Metal", Color3.fromRGB(26,30,54), tilt = Vector3.new(0,0,-14) }, -- left shoulder pauldron (sode)
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(-1.02,2.0,0), "Slate", Color3.fromRGB(32,34,46), tilt = Vector3.new(0,0,6) }, -- left arm (baseline thickness)
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(1.02,1.9,0.15), "Slate", Color3.fromRGB(32,34,46), tilt = Vector3.new(18,0,-10) }, -- right arm  extended to grip katana out to the side
		{ "Block", Vector3.new(1.7,1.6,1.55), Vector3.new(0,3.35,0), "SmoothPlastic", Color3.fromRGB(22,24,34) }, -- head (dark, mostly under helmet)  baseline chibi head
		{ "Block", Vector3.new(1.85,0.95,1.7), Vector3.new(0,3.9,0), "Metal", Color3.fromRGB(30,34,60) }, -- kabuto helmet dome (indigo/charcoal)
		{ "Block", Vector3.new(1.95,0.32,0.55), Vector3.new(0,3.28,0.62), "Metal", Color3.fromRGB(22,24,36), tilt = Vector3.new(-24,0,0) }, -- helmet brim / mabizashi peak over the face
		{ "Wedge", Vector3.new(0.28,1.1,0.9), Vector3.new(0,4.75,-0.1), "Metal", Color3.fromRGB(212,178,92), tilt = Vector3.new(20,0,0) }, -- golden maedate horn crest sweeping up from helmet front
		{ "Block", Vector3.new(1.5,0.45,0.35), Vector3.new(0,3.05,0.72), "Fabric", Color3.fromRGB(20,22,30) }, -- menpo lower face-mask guard
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(-0.34,3.42,0.8), "SmoothPlastic", Color3.fromRGB(12,14,20) }, -- left eye  matte dark, unified roster face style (+Z face
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(0.34,3.42,0.8), "SmoothPlastic", Color3.fromRGB(12,14,20) }, -- right eye  matte dark, unified roster face style
		{ "Block", Vector3.new(0.22,0.22,0.9), Vector3.new(1.52,1.45,0.35), "WoodPlanks", Color3.fromRGB(58,40,30), tilt = Vector3.new(20,0,-10) }, -- katana tsuka (wrapped hilt) in right hand
		{ "Cylinder", Vector3.new(0.34,0.14,0.34), Vector3.new(1.6,1.68,0.48), "Metal", Color3.fromRGB(36,32,24), tilt = Vector3.new(20,0,80) }, -- tsuba round guard, aligned to blade axis
		{ "Block", Vector3.new(0.16,3.0,0.16), Vector3.new(1.82,2.62,0.98), "Metal", Color3.fromRGB(210,220,230), tilt = Vector3.new(20,0,-10) }, -- katana blade (steel core) thrust up-and-out to the right
		{ "Block", Vector3.new(0.08,3.0,0.2), Vector3.new(1.88,2.62,1.05), "Neon", Color3.fromRGB(53,230,255), tilt = Vector3.new(20,0,-10), light = true }, -- glowing cyan katana edge  the ONE emissive accent
	}},
	Onmyoji = { accent = Color3.fromRGB(130,220,235), parts = {
		{ "Cylinder", Vector3.new(1.9,0.35,1.9), Vector3.new(0,0.05,0), "Marble", Color3.fromRGB(210,222,236) }, -- round dais/base on the y=0 plane
		{ "Block", Vector3.new(0.55,1.1,0.55), Vector3.new(-0.42,0.6,0), "Fabric", Color3.fromRGB(235,240,246) }, -- left leg  upsized to roster baseline, sits on dais top
		{ "Block", Vector3.new(0.55,1.1,0.55), Vector3.new(0.42,0.6,0), "Fabric", Color3.fromRGB(235,240,246) }, -- right leg  upsized to roster baseline
		{ "Wedge", Vector3.new(2.2,1.2,1.6), Vector3.new(0,0.62,0), "Fabric", Color3.fromRGB(238,242,248), rotY = 180 }, -- robe skirt/hem flaring to the feet, covers the leg-dais 
		{ "Block", Vector3.new(1.5,1.5,0.9), Vector3.new(0,1.9,0), "Fabric", Color3.fromRGB(246,249,252) }, -- torso trunk  pale robe body, PrimaryPart candidate
		{ "Block", Vector3.new(1.62,0.35,1.0), Vector3.new(0,1.42,0), "Fabric", Color3.fromRGB(92,120,158) }, -- indigo obi/sash cinching the waist
		{ "Block", Vector3.new(1.6,0.5,1.0), Vector3.new(0,2.55,0), "Fabric", Color3.fromRGB(120,150,190) }, -- blue collar/shoulder yoke
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(-1.02,1.98,0.1), "Fabric", Color3.fromRGB(244,247,251), tilt = Vector3.new(12,0,8) }, -- left sleeve/arm  normalized thickness, holding staff
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(1.02,1.98,0.05), "Fabric", Color3.fromRGB(244,247,251), tilt = Vector3.new(0,0,-6) }, -- right sleeve/arm resting at side  normalized thickness
		{ "Ball", Vector3.new(0.42,0.42,0.42), Vector3.new(-1.22,1.32,0.45), "SmoothPlastic", Color3.fromRGB(236,214,190) }, -- left hand gripping the staff shaft (nudged onto shaft)
		{ "Block", Vector3.new(1.7,1.6,1.55), Vector3.new(0,3.4,0), "SmoothPlastic", Color3.fromRGB(238,214,190) }, -- BIG chibi head, pale skin
		{ "Block", Vector3.new(1.78,0.55,1.62), Vector3.new(0,4.02,0), "Fabric", Color3.fromRGB(28,32,44) }, -- black hair fringe cap over the brow
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(-0.34,3.44,0.8), "SmoothPlastic", Color3.fromRGB(40,44,58) }, -- left eye  matte (demoted from neon so the orb is the sin
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(0.34,3.44,0.8), "SmoothPlastic", Color3.fromRGB(40,44,58) }, -- right eye  matte to match
		{ "Wedge", Vector3.new(1.0,1.5,0.7), Vector3.new(0,5.35,-0.15), "Fabric", Color3.fromRGB(20,24,34), rotY = 180, tilt = Vector3.new(14,0,0) }, -- tall pointed eboshi hat  unmistakable onmyoji topper
		{ "Block", Vector3.new(1.15,0.28,1.05), Vector3.new(0,4.42,0), "Fabric", Color3.fromRGB(36,40,52) }, -- hat base band seating the eboshi
		{ "Cylinder", Vector3.new(0.16,4.6,0.16), Vector3.new(-1.35,2.6,0.45), "WoodPlanks", Color3.fromRGB(150,110,74), tilt = Vector3.new(6,0,4) }, -- staff shaft, held in left hand, rising past the head
		{ "Ball", Vector3.new(0.72,0.72,0.72), Vector3.new(-1.5,5.05,0.6), "Neon", Color3.fromRGB(130,220,235), light = true }, -- ice-blue glowing orb crowning the staff  the ONE emissiv
	}},
	Archer = { accent = C.violet, parts = {
		{ "Cylinder", Vector3.new(0.55,1.1,0.55), Vector3.new(-0.42,0.55,0.12), "Fabric", Color3.fromRGB(120,110,95), rotY = 8 }, -- left leg, staggered forward for drawn stance  baseline s
		{ "Cylinder", Vector3.new(0.55,1.1,0.55), Vector3.new(0.42,0.55,-0.12), "Fabric", Color3.fromRGB(120,110,95), rotY = -8 }, -- right leg, set back (archer's brace)  baseline size
		{ "Block", Vector3.new(1.5,1.5,0.9), Vector3.new(0,1.85,0), "Fabric", Color3.fromRGB(225,220,205) }, -- torso, light tunic  PrimaryPart candidate
		{ "Block", Vector3.new(1.55,0.42,0.95), Vector3.new(0,1.28,0), "Fabric", Color3.fromRGB(90,80,70) }, -- belt / tunic hem wrap (anime layering, hides seam)
		{ "Block", Vector3.new(0.5,1.2,0.35), Vector3.new(-0.42,2.6,-0.62), "WoodPlanks", Color3.fromRGB(95,70,50), rotY = -12, tilt = Vector3.new(18,0,10) }, -- quiver slung across the back
		{ "Cylinder", Vector3.new(0.09,0.95,0.09), Vector3.new(-0.5,3.2,-0.7), "WoodPlanks", Color3.fromRGB(205,185,150), tilt = Vector3.new(20,0,14) }, -- arrow shafts + fletching jutting from quiver
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(1.02,2.0,0.55), "Fabric", Color3.fromRGB(225,220,205), tilt = Vector3.new(0,0,-10) }, -- front arm extended forward, gripping the bow  baseline t
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(-1.0,2.05,-0.35), "Fabric", Color3.fromRGB(225,220,205), tilt = Vector3.new(0,-25,20) }, -- back arm drawn to the ear  lengthened to baseline 1.25
		{ "Block", Vector3.new(0.75,0.35,0.7), Vector3.new(1.0,2.65,0.15), "Metal", Color3.fromRGB(150,150,160) }, -- shoulder guard / anime pauldron on draw side
		{ "Block", Vector3.new(0.12,1.4,0.28), Vector3.new(1.7,2.5,0.75), "WoodPlanks", Color3.fromRGB(105,75,55), tilt = Vector3.new(18,0,0) }, -- bow upper limb (C-arc top)
		{ "Block", Vector3.new(0.12,1.4,0.28), Vector3.new(1.7,1.5,0.75), "WoodPlanks", Color3.fromRGB(105,75,55), tilt = Vector3.new(-18,0,0) }, -- bow lower limb (C-arc bottom)
		{ "Block", Vector3.new(0.14,0.55,0.26), Vector3.new(1.72,2.0,0.68), "WoodPlanks", Color3.fromRGB(120,88,62) }, -- bow grip / riser closing the C
		{ "Cylinder", Vector3.new(0.05,2.3,0.05), Vector3.new(1.5,2.0,0.86), "Neon", Color3.fromRGB(168,120,255), light = true }, -- the ONE emissive accent: glowing violet bowstring + nock
		{ "Ball", Vector3.new(1.7,1.6,1.55), Vector3.new(0,3.35,0), "SmoothPlastic", Color3.fromRGB(245,225,200) }, -- big chibi head
		{ "Wedge", Vector3.new(1.45,0.75,1.35), Vector3.new(0,4.05,-0.05), "SmoothPlastic", Color3.fromRGB(60,55,80), tilt = Vector3.new(-8,0,0) }, -- short spiky hair topper (class cue)
		{ "Block", Vector3.new(1.75,0.28,1.6), Vector3.new(0,3.58,0), "Fabric", Color3.fromRGB(140,100,215) }, -- violet headband across the brow (class cue)
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(-0.32,3.42,0.8), "SmoothPlastic", Color3.fromRGB(30,26,40) }, -- left eye  matte dark, unified roster face style
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(0.32,3.42,0.8), "SmoothPlastic", Color3.fromRGB(30,26,40) }, -- right eye  matte dark, unified roster face style
	}},
	Monk = { accent = C.gold, parts = {
		{ "Cylinder", Vector3.new(0.55,1.1,0.55), Vector3.new(-0.42,0.55,0), "Fabric", Color3.fromRGB(120,58,40) }, -- left leg  dark saffron trouser wrap, baseline size
		{ "Cylinder", Vector3.new(0.55,1.1,0.55), Vector3.new(0.42,0.55,0), "Fabric", Color3.fromRGB(120,58,40) }, -- right leg  dark saffron trouser wrap, baseline size
		{ "Block", Vector3.new(1.5,1.5,0.9), Vector3.new(0,1.85,0), "Fabric", Color3.fromRGB(163,74,42) }, -- torso  russet monk robe trunk, PrimaryPart candidate
		{ "Wedge", Vector3.new(1.55,1.5,0.18), Vector3.new(-0.15,1.95,0.5), "Fabric", Color3.fromRGB(255,178,60), tilt = Vector3.new(0,0,32) }, -- kesa sash  bright orange band across the chest (signatur
		{ "Block", Vector3.new(1.6,0.35,1.0), Vector3.new(0,1.12,0), "Fabric", Color3.fromRGB(120,58,40) }, -- waist knot/belt cinch, hides leg-torso seam
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(-1.02,2.0,0), "SmoothPlastic", Color3.fromRGB(224,180,140) }, -- left arm  holds the staff upright, baseline thickness
		{ "Cylinder", Vector3.new(0.4,1.25,0.4), Vector3.new(1.02,2.3,0), "SmoothPlastic", Color3.fromRGB(224,180,140), tilt = Vector3.new(18,0,-40) }, -- right arm  raised into a fist stance, baseline thickness
		{ "Ball", Vector3.new(0.5,0.5,0.5), Vector3.new(1.4,2.98,0.15), "SmoothPlastic", Color3.fromRGB(224,180,140) }, -- raised right fist knuckles, seated at arm end
		{ "Ball", Vector3.new(1.7,1.6,1.55), Vector3.new(0,3.35,0), "SmoothPlastic", Color3.fromRGB(233,190,150) }, -- head  BIG bald round chibi head (signature shaved dome),
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(-0.32,3.42,0.8), "SmoothPlastic", Color3.fromRGB(20,16,14) }, -- left eye  matte dark dot, unified roster face style
		{ "Block", Vector3.new(0.2,0.2,0.16), Vector3.new(0.32,3.42,0.8), "SmoothPlastic", Color3.fromRGB(20,16,14) }, -- right eye  matte dark dot, unified roster face style
		{ "Cylinder", Vector3.new(0.24,0.16,0.24), Vector3.new(0,3.72,0.8), "Marble", Color3.fromRGB(180,130,90), tilt = Vector3.new(90,0,0) }, -- forehead tilaka/ash mark  ascetic face read, raised abov
		{ "Cylinder", Vector3.new(0.22,4.3,0.22), Vector3.new(-1.42,2.15,0.15), "WoodPlanks", Color3.fromRGB(110,74,44) }, -- shakujo staff  tall pilgrim staff held upright (signatur
		{ "Cylinder", Vector3.new(0.55,0.5,0.55), Vector3.new(-1.42,4.35,0.15), "Neon", Color3.fromRGB(255,209,92), tilt = Vector3.new(90,0,0), light = true }, -- shakujo ringed finial  the ONE glowing gold emissive acc
		{ "Ball", Vector3.new(0.42,0.42,0.42), Vector3.new(-1.42,4.72,0.15), "Metal", Color3.fromRGB(212,168,70) }, -- tama jewel atop the finial
		{ "Block", Vector3.new(0.85,0.5,0.5), Vector3.new(-1.15,2.55,0.05), "Fabric", Color3.fromRGB(255,178,60) }, -- kesa shoulder drape over the left arm  orange accent tie
	}},
}
local function buildModel(id: string): Model
	local spec = MODELS[id]
	local m = Instance.new("Model")
	local trunk
	for _, pd in spec.parts do
		local p = Instance.new("Part")
		p.Shape = (Enum.PartType :: any)[pd[1]]
		p.Size = pd[2]
		local cf = CFrame.new(pd[3])
		if pd.rotY then cf = cf * CFrame.Angles(0, rad(pd.rotY), 0) end
		if pd.tilt then cf = cf * CFrame.Angles(rad(pd.tilt.X), rad(pd.tilt.Y), rad(pd.tilt.Z)) end
		p.CFrame = cf
		p.Color = pd[5]
		p.Material = (Enum.Material :: any)[pd[4]]
		p.Anchored = true; p.CanCollide = false; p.CastShadow = false
		p.Parent = m
		if pd.light then
			local pl = Instance.new("PointLight")
			pl.Color = pd[5]; pl.Brightness = 2; pl.Range = 6; pl.Parent = p
		end
		if not trunk and pd[4] ~= "Neon" then trunk = p end
	end
	m.PrimaryPart = trunk or m:FindFirstChildOfClass("Part")
	m:PivotTo(CFrame.new()) -- pivot at origin => clean spin
	return m
end
local function frameCamera(cam: Camera, _model: Model)
	-- all warriors share the ~4.6-stud skeleton, so frame by a fixed vertical extent (not the bbox,
	-- which balloons from tall staffs/katanas and shrinks the body). Camera sits on the +Z (front) side.
	local halfFov = rad(cam.FieldOfView) * 0.5
	local frameH = 5.6 -- studs to fit vertically: the ~4.6 figure + a little head/weapon room
	local dist = (frameH * 0.5) / math.tan(halfFov)
	local el, az = rad(12), rad(20) -- gentle look-up, slight 3/4 so side-held weapons separate from the torso
	local h = math.cos(el)
	local offset = Vector3.new(h * math.sin(az), math.sin(el), h * math.cos(az)) -- +Z side => we see the FACE
	local target = Vector3.new(0, 2.3, 0)
	cam.CFrame = CFrame.lookAt(target + offset * dist, target)
end
-- ONE shared spinner loop for ALL viewports (raw dt: keeps turning during hit-stop) + a subtle idle bob
local spinModels: { any } = {}
local spinT = 0
local function addSpinner(model: Model, speed: number)
	table.insert(spinModels, { model = model, angle = 0, speed = speed, phase = #spinModels * 0.9 })
end
local function removeSpinner(model: Model)
	for i = #spinModels, 1, -1 do
		if spinModels[i].model == model then table.remove(spinModels, i) end
	end
end
RunService.RenderStepped:Connect(function(dt)
	spinT += dt
	for _, s in spinModels do
		if s.model.Parent then
			s.angle += s.speed * dt
			local ph = spinT * math.pi + s.phase -- ~0.5 Hz breathing bob so they feel alive, not turntable-stiff
			local bob = math.sin(ph) * 0.06
			local roll = math.sin(ph) * rad(1.5)
			s.model:PivotTo(CFrame.new(0, bob, 0) * CFrame.Angles(0, s.angle, roll))
		end
	end
end)
local function makeTowerViewport(parent: Instance, def: any): any
	local vp = Instance.new("ViewportFrame")
	vp.Size = UDim2.fromScale(1.9, 3.9)
	vp.AnchorPoint = Vector2.new(0.5, 1); vp.Position = UDim2.fromScale(0.5, 1.05)
	vp.BackgroundTransparency = 1; vp.ZIndex = 15
	vp.Ambient = Color3.fromRGB(86, 104, 150)     -- SATURATED-COOL dusk fill: shadows get hue, not flat grey
	vp.LightColor = Color3.fromRGB(255, 236, 200) -- warm key (dusk sun)
	vp.LightDirection = Vector3.new(-1, -0.55, -0.35).Unit -- angled upper-left-front => cheekbone/shoulder modeling
	vp.Parent = parent
	local world = Instance.new("WorldModel"); world.Parent = vp
	-- CONTACT SHADOW: a flat dark disc at the feet (parented to the WORLD, not the model, so it
	-- stays put while the model spins) => the warrior reads as PLACED, not floating.
	local sh = Instance.new("Part")
	sh.Shape = Enum.PartType.Cylinder
	sh.Size = Vector3.new(0.1, 3.0, 3.0) -- thin along its axis; rotate the axis to point up => a ground disc
	sh.CFrame = CFrame.new(0.35, 0.05, 0.2) * CFrame.Angles(0, 0, rad(90))
	sh.Color = Color3.new(0, 0, 0); sh.Material = Enum.Material.SmoothPlastic
	sh.Transparency = 0.52; sh.Anchored = true; sh.CanCollide = false; sh.CastShadow = false
	sh.Parent = world
	local model = buildModel(def.id)
	model.Parent = world
	local cam = Instance.new("Camera")
	cam.FieldOfView = 26; cam.Parent = vp -- LONG lens: product-shot flatten, stops the head ballooning
	vp.CurrentCamera = cam
	frameCamera(cam, model)
	addSpinner(model, rad(20))
	return { vp = vp, model = model }
end

local slots = {}
local function placeFighter(node: any, id: string)
	local def = FIGHTERS[id]
	if state.yen < def.cost then banner("NEED \u{00A5}", C.red); return end
	setYen(state.yen - def.cost)
	node.plus.Visible = false
	-- turn the node panel into a warm stone foundation pad so the tower stands ON the ground
	node.frame.BackgroundColor3 = C.pad; node.frame.BackgroundTransparency = 0.06
	-- a real rotating 3D model in a ViewportFrame (replaces the flat cel card + glyph)
	local vpData = makeTowerViewport(node.frame, def)
	local t = vpData.vp -- `t` is now the ViewportFrame; the rest of placeFighter uses `t` unchanged
	local tw = { id = id, node = node, cd = 0, frame = t, model = vpData.model, pocket = vpData.pocket }
	node.tower = tw; table.insert(state.towers, tw)
	-- aura ring
	local aura = frame(t, "Aura"); aura.BackgroundTransparency = 1; aura.Size = UDim2.fromScale(1.3, 1.3)
	aura.AnchorPoint = Vector2.new(0.5, 0.5); aura.Position = UDim2.fromScale(0.5, 0.5); aura.ZIndex = 14
	stroke(aura, def.color, 2, 0.4); corner(aura, 12)
	button(t).MouseButton1Click:Connect(function()
		-- inspect: pulse the range aura (upgrades are drafted between waves now)
		local S = fStats(id)
		local r = math.clamp(S.range * 4.2, 1.3, 2.6)
		TweenService:Create(aura, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 1, true),
			{ Size = UDim2.fromScale(r, r) }):Play()
	end)
	t.Size = UDim2.fromScale(0.3, 0.3)
	TweenService:Create(t, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) }):Play()
	hitSpark(select(1, pxOf(node.pos)), select(2, pxOf(node.pos)), def.color)
end

-- a boss can SMASH a placed fighter: free the node, shatter the frame, re-summon later
local function removeFighter(tw: any)
	local node = tw.node
	node.tower = nil
	node.plus.Visible = true
	node.frame.BackgroundColor3 = C.panel; node.frame.BackgroundTransparency = 0.25 -- revert pad to empty slot
	local i = table.find(state.towers, tw); if i then table.remove(state.towers, i) end
	if tw.model then removeSpinner(tw.model) end -- stop spinning the model we're about to destroy
	if tw.pocket then local p = tw.pocket; TweenService:Create(p, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play(); task.delay(0.2, function() p:Destroy() end) end
	local fx = tw.frame
	TweenService:Create(fx, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Size = UDim2.fromScale(0.01, 0.01), Rotation = 55 }):Play()
	task.delay(0.2, function() fx:Destroy() end)
end

local pickerOpen = false
local function openPicker(node: any)
	if node.tower or not state.running or pickerOpen then return end
	local owned = {}
	for id in RunState.owned do table.insert(owned, id) end
	if #owned == 1 then placeFighter(node, owned[1]); return end
	pickerOpen = true
	local menu = frame(root, "Picker"); menu.AnchorPoint = Vector2.new(0.5, 0.5)
	local nx, ny = pxOf(node.pos)
	menu.Position = UDim2.fromScale(nx, ny); menu.Size = UDim2.fromScale(0.16, 0.055 * #owned)
	menu.BackgroundColor3 = C.panel; menu.ZIndex = 50; corner(menu, 10); stroke(menu, C.cyan, 2, 0.2)
	local ll = Instance.new("UIListLayout"); ll.Padding = UDim.new(0, 4); ll.Parent = menu
	local pad = Instance.new("UIPadding"); pad.PaddingTop = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4); pad.PaddingLeft = UDim.new(0, 4); pad.PaddingRight = UDim.new(0, 4); pad.Parent = menu
	local function close() pickerOpen = false; menu:Destroy() end
	for _, id in owned do
		local def = FIGHTERS[id]
		local row = cel(menu, def.color, 8); row.Size = UDim2.new(1, 0, 0, 34); row.ZIndex = 51
		local lbl = text(row, def.glyph .. "  " .. def.name .. "  \u{00A5}" .. def.cost, 13, C.ink0); lbl.Font = FONT; lbl.Size = UDim2.fromScale(1, 1); lbl.ZIndex = 52
		button(row).MouseButton1Click:Connect(function() close(); placeFighter(node, id) end)
	end
	task.delay(4, function() if menu.Parent then close() end end)
end

for _, p in NODES do
	local node = frame(board, "Node")
	node.AnchorPoint = Vector2.new(0.5, 0.5); node.Position = UDim2.fromScale(p.X, p.Y)
	node.Size = UDim2.fromScale(0.11, 0.06); node.BackgroundColor3 = C.panel; node.BackgroundTransparency = 0.25
	node.ZIndex = 6; corner(node, 10); stroke(node, C.panelHi, 2, 0.4)
	local plus = text(node, "+", 22, C.dim); plus.Font = FONT; plus.Size = UDim2.fromScale(1, 1)
	local n = { frame = node, pos = p, tower = nil, plus = plus }
	button(node).MouseButton1Click:Connect(function() openPicker(n) end)
	table.insert(slots, n)
end

-- ===== fire =====
local function fire(tw: any, e: any)
	local def = FIGHTERS[tw.id]
	local S = fStats(tw.id)
	local ex, ey = pxOf(pathPos(e.progress))
	local nx, ny = pxOf(tw.node.pos)
	local dmg = S.dmg
	local crit = math.random() < S.crit
	if crit then dmg = math.floor(dmg * S.critMul) end
	if def.kind == "slash" then slashFlash(ex, ey, def.color)
	elseif def.kind == "beam" then
		local b = frame(fxLayer, "Beam"); b.BackgroundColor3 = def.color; b.AnchorPoint = Vector2.new(0.5, 0.5)
		local dx, dy = ex - nx, ey - ny
		b.Size = UDim2.fromScale(math.sqrt(dx * dx + dy * dy), 0.006); b.Position = UDim2.fromScale((nx + ex) / 2, (ny + ey) / 2)
		b.Rotation = math.deg(math.atan2(dy, dx)); b.ZIndex = 42; corner(b, 2)
		TweenService:Create(b, TweenInfo.new(0.1), { BackgroundTransparency = 1 }):Play()
		task.delay(0.11, function() b:Destroy() end)
	else
		local p = frame(fxLayer, "Bolt"); p.BackgroundColor3 = def.color; p.AnchorPoint = Vector2.new(0.5, 0.5)
		p.Size = UDim2.fromScale(0.014, 0.014); p.Position = UDim2.fromScale(nx, ny); p.ZIndex = 42; corner(p, 6)
		TweenService:Create(p, TweenInfo.new(0.1), { Position = UDim2.fromScale(ex, ey) }):Play()
		task.delay(0.1, function() p:Destroy() end)
	end
	if S.slow > 0 then e.slowT = S.slow end
	damageEnemy(e, math.floor(dmg), crit, tw.id)
end

-- ===== one Heartbeat =====
local hbConn: RBXScriptConnection
hbConn = RunService.Heartbeat:Connect(function(raw)
	if not state.running then return end
	local dt = raw * timeScale
	if state.drafting then return end
	if #state.queue > 0 and #state.enemies < MAX_LIVE then
		local def = state.queue[1]; def._t = (def._t or 0) + dt
		if def._t >= (def._gap or 0) then table.remove(state.queue, 1); spawnOne(def) end
	end
	for i = #state.enemies, 1, -1 do
		local e = state.enemies[i]
		if e.active then
			-- BOSS: smash the nearest fighter it passes (towers CAN be destroyed at higher levels)
			if e.boss then
				e.smashCd = (e.smashCd or 3.2) - dt
				if e.smashCd <= 0 and #state.towers > 0 then
					local bp = pathPos(e.progress)
					local victim, vd = nil, 0.17 * 0.17
					for _, tw in state.towers do
						local dx = bp.X - tw.node.pos.X; local dy = bp.Y - tw.node.pos.Y
						local d2 = dx * dx + dy * dy
						if d2 <= vd then victim, vd = tw, d2 end
					end
					if victim then
						local vx, vy = pxOf(victim.node.pos)
						removeFighter(victim)
						banner("FIGHTER SMASHED", C.red); screenShake(9, 5); screenFlash(C.red, 0.45); hitStop(0.08)
						hitSpark(vx, vy, C.red); slashFlash(vx, vy, C.red)
						e.smashCd = 3.4
					else
						e.smashCd = 0.5
					end
				end
			end
			if e.slowT > 0 then e.slowT -= dt end
			e.speed = e.slowT > 0 and e.baseSpeed * 0.45 or e.baseSpeed
			e.progress += e.speed * dt
			if e.progress >= 1 then
				releaseEnemy(e)
				setLives(state.lives - (e.boss and 3 or 1))
				screenShake(6, 4); screenFlash(C.red, 0.5)
				if state.lives <= 0 then endRun(); return end
			else
				local p = pathPos(e.progress)
				e.body.Position = UDim2.fromScale(p.X, p.Y)
			end
		end
	end
	for _, tw in state.towers do
		tw.cd -= dt
		if tw.cd <= 0 then
			local S = fStats(tw.id)
			local best, bp = nil, -1
			for _, e in state.enemies do
				if e.active then
					local dx = pathPos(e.progress).X - tw.node.pos.X
					local dy = pathPos(e.progress).Y - tw.node.pos.Y
					if (dx * dx + dy * dy) <= S.range * S.range and e.progress > bp then best, bp = e, e.progress end
				end
			end
			if best then fire(tw, best); tw.cd = S.rate end
		end
	end
end)

-- ===== draft =====
local POOL = { "Onmyoji", "Archer", "Monk" }
local function draftCards(): { any }
	local cards = {}
	-- summon un-owned fighters
	for _, id in POOL do if not RunState.owned[id] then local d = FIGHTERS[id]
		table.insert(cards, { kind = "new", id = id, title = "SUMMON " .. d.name, glyph = d.glyph, color = d.color,
			tip = d.element .. " \u{2022} " .. (d.slow > 0 and "slows + chips" or "dmg dealer") }) end end
	-- one un-owned TRAIT per owned fighter (this is the class curation)
	for id in RunState.owned do
		local ownedT = RunState.traits[id] or {}
		local avail = {}
		for _, tr in TRAITS[id] or {} do if not ownedT[tr.key] then table.insert(avail, tr) end end
		if #avail > 0 then
			local tr = avail[math.random(1, #avail)]
			local d = FIGHTERS[id]
			table.insert(cards, { kind = "trait", id = id, trait = tr,
				title = d.name .. " \u{2022} " .. tr.name, glyph = d.glyph, color = d.color, tip = tr.tip })
		end
	end
	table.insert(cards, { kind = "eco", id = "Yen", title = "WAR CHEST", glyph = "\u{00A5}", color = C.gold, tip = "+40 \u{00A5} now" })
	local out = {}
	for _ = 1, 3 do if #cards == 0 then break end local x = math.random(1, #cards); table.insert(out, cards[x]); table.remove(cards, x) end
	return out
end
local function applyCard(c: any)
	if c.kind == "new" then
		RunState.owned[c.id] = true; RunState.traits[c.id] = {}; RunState.upgrades[c.id] = 0; RunState.dmgByType[c.id] = 0
	elseif c.kind == "trait" then
		RunState.traits[c.id] = RunState.traits[c.id] or {}
		RunState.traits[c.id][c.trait.key] = true
		RunState.upgrades[c.id] = (RunState.upgrades[c.id] or 0) + 1 -- tier = trait count (drives tray star pips)
	elseif c.kind == "eco" then setYen(state.yen + 40) end
	refreshTray()
end
local function showDraft()
	state.drafting = true
	local drawn = draftCards()
	local ov = frame(root, "Draft"); ov.Size = UDim2.fromScale(1, 1); ov.BackgroundColor3 = C.ink0; ov.BackgroundTransparency = 0.35; ov.ZIndex = 52
	local title = shout(ov, "FORGE YOUR CLASS", 28, C.cyan); title.Position = UDim2.fromScale(0, 0.16); title.Size = UDim2.fromScale(1, 0.08); title.ZIndex = 53
	local rowf = frame(ov, "Row"); rowf.BackgroundTransparency = 1; rowf.AnchorPoint = Vector2.new(0.5, 0.5); rowf.Position = UDim2.fromScale(0.5, 0.52); rowf.Size = UDim2.fromScale(0.82, 0.5); rowf.ZIndex = 53
	local ll = Instance.new("UIListLayout"); ll.FillDirection = Enum.FillDirection.Horizontal; ll.HorizontalAlignment = Enum.HorizontalAlignment.Center; ll.VerticalAlignment = Enum.VerticalAlignment.Center; ll.Padding = UDim.new(0, 18); ll.Parent = rowf
	local done = false
	local function choose(c: any) if done then return end done = true; applyCard(c); ov:Destroy(); state.drafting = false end
	for _, c in drawn do
		local card = cel(rowf, C.panel, 14); card.Size = UDim2.fromScale(0.28, 1); card.ZIndex = 54; stroke(card, c.color, 3, 0)
		local icon = cel(card, c.color, 12); icon.AnchorPoint = Vector2.new(0.5, 0); icon.Position = UDim2.fromScale(0.5, 0.08); icon.Size = UDim2.fromScale(0.42, 0.32); icon.ZIndex = 55
		local g = text(icon, c.glyph, 34, C.ink0); g.Font = FONT; g.Size = UDim2.fromScale(1, 1); g.ZIndex = 56
		local nm = shout(card, c.title, 17, c.color); nm.Position = UDim2.fromScale(0, 0.5); nm.Size = UDim2.fromScale(1, 0.12); nm.ZIndex = 55
		local tp = text(card, c.tip, 13, C.dim); tp.Position = UDim2.fromScale(0.06, 0.68); tp.Size = UDim2.fromScale(0.88, 0.2); tp.TextWrapped = true; tp.ZIndex = 55
		local b = button(card); b.ZIndex = 57
		b.MouseButton1Click:Connect(function() choose(c) end)
		b.MouseEnter:Connect(function() TweenService:Create(card, TweenInfo.new(0.1), { Size = UDim2.fromScale(0.3, 1.04) }):Play() end)
		b.MouseLeave:Connect(function() TweenService:Create(card, TweenInfo.new(0.1), { Size = UDim2.fromScale(0.28, 1) }):Play() end)
	end
	if DEBUG.autoPlay then task.delay(1.0, function() if not done then choose(drawn[1]) end end) end
end

-- ===== boss intro card =====
local function bossIntro(name: string, epithet: string, onDone: () -> ())
	local ov = frame(root, "Intro"); ov.Size = UDim2.fromScale(1, 1); ov.BackgroundColor3 = C.ink0; ov.BackgroundTransparency = 0.1; ov.ZIndex = 55
	for i = 0, 1 do
		local bar = frame(ov, "Bar"); bar.BackgroundColor3 = i == 0 and C.magenta or C.cyan; bar.Size = UDim2.fromScale(1.5, 0.16)
		bar.Rotation = -12; bar.AnchorPoint = Vector2.new(0.5, 0.5); bar.Position = UDim2.fromScale(1.6, i == 0 and 0.4 or 0.6); bar.ZIndex = 56
		TweenService:Create(bar, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, i == 0 and 0.4 or 0.6) }):Play()
	end
	-- procedural boss portrait
	local port = cel(ov, C.red, 16); port.AnchorPoint = Vector2.new(0.5, 0.5); port.Position = UDim2.fromScale(0.5, 0.42); port.Size = UDim2.fromScale(0.001, 0.001); port.ZIndex = 57
	local face = text(port, "\u{9B3C}", 60, C.ink0); face.Font = FONT; face.Size = UDim2.fromScale(1, 1); face.ZIndex = 58
	TweenService:Create(port, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.22, 0.28) }):Play()
	task.delay(0.25, function() screenShake(8, 4); speedLines(); screenFlash(C.red, 0.5); hitStop(0.08) end)
	local nm = shout(ov, name, 48, C.red); nm.Position = UDim2.fromScale(0, 0.6); nm.Size = UDim2.fromScale(1, 0.12); nm.ZIndex = 57
	local ep = shout(ov, epithet, 22, C.gold); ep.Position = UDim2.fromScale(0, 0.72); ep.Size = UDim2.fromScale(1, 0.06); ep.ZIndex = 57
	task.delay(1.4, function() ov:Destroy(); onDone() end)
end

-- ===== wave flow =====
local function waveClear(): boolean
	if #state.queue > 0 then return false end
	for _, e in state.enemies do if e.active then return false end end
	return true
end
local function startWave()
	state.wave += 1
	waveT.Text = "WAVE " .. state.wave
	local isBoss = (DEBUG.forceBossWave > 0 and state.wave >= DEBUG.forceBossWave) or (state.wave % 5 == 0)
	if isBoss then
		bossIntro("VULCANINE", "THE EMBER FOX", function()
			banner("WAVE " .. state.wave, C.red)
			local list = schedule(state.wave)
			-- prepend a boss
			table.insert(list, 1, { hp = math.floor(14 * (1.15 ^ state.wave)) * 10, speed = 0.03 + state.wave * 0.001, boss = true })
			local gap = math.max(0.35, 0.9 - state.wave * 0.02)
			for _, d in list do d._gap = gap; table.insert(state.queue, d) end
		end)
	else
		banner("WAVE " .. state.wave, C.cyan)
		local gap = math.max(0.35, 0.9 - state.wave * 0.02)
		for _, d in schedule(state.wave) do d._gap = gap; table.insert(state.queue, d) end
	end
end

task.spawn(function()
	startWave()
	while state.running do
		task.wait(0.4)
		if state.running and not state.drafting and waveClear() then
			showDraft()
			local g = 0
			while state.drafting and state.running and g < 600 do task.wait(0.1); g += 1 end
			if state.running then startWave() end
		end
	end
end)

-- DEBUG auto-place + auto-upgrade
if DEBUG.autoPlay then
	task.spawn(function()
		local order = { "Ronin", "Onmyoji", "Archer", "Monk" }
		local k = 0
		while state.running do
			for _, n in slots do
				if not n.tower and not state.drafting then
					if DEBUG.rich then -- place all 4 types in rotation (skip the picker menu)
						k += 1
						local id = order[((k - 1) % #order) + 1]
						if state.yen >= FIGHTERS[id].cost then placeFighter(n, id); task.wait(0.15) end
					elseif state.yen >= 18 then
						openPicker(n); task.wait(0.1)
					end
				end
			end
			task.wait(0.7)
		end
	end)
end

-- ===== run over =====
function endRun()
	if not state.running then return end
	state.running = false
	screenFlash(C.red, 0.5); screenShake(10, 8)
	local ov = frame(root, "Over"); ov.Size = UDim2.fromScale(1, 1); ov.BackgroundColor3 = C.ink0; ov.BackgroundTransparency = 0.12; ov.ZIndex = 90
	local big = shout(ov, "OVERRUN", 60, C.red); big.AnchorPoint = Vector2.new(0.5, 0.5); big.Position = UDim2.fromScale(0.5, 0.38); big.Size = UDim2.fromScale(0.8, 0.16); big.ZIndex = 91
	local sub = text(ov, "You held to WAVE " .. state.wave, 22, C.white); sub.Font = FONT; sub.Position = UDim2.fromScale(0, 0.54); sub.Size = UDim2.fromScale(1, 0.06); sub.ZIndex = 91
	local again = Instance.new("TextButton"); again.AnchorPoint = Vector2.new(0.5, 0.5); again.Position = UDim2.fromScale(0.5, 0.68); again.Size = UDim2.fromScale(0.34, 0.1)
	again.BackgroundColor3 = C.cyan; again.Text = "RUN IT BACK"; again.Font = FONT; again.TextSize = 22; again.TextColor3 = C.ink0; again.ZIndex = 91; corner(again, 10); stroke(again, C.ink0, 3, 0); again.Parent = ov
	again.MouseButton1Click:Connect(function()
		gui:Destroy(); if hbConn then hbConn:Disconnect() end
		local clone = script:Clone(); clone.Parent = script.Parent; clone.Disabled = false
	end)
	if DEBUG.autoPlay then task.delay(2.5, function() again.MouseButton1Click:Fire() end) end
end

print("[NeonGauntlet] ready")
