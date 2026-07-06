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
-- ONE cohesive clean deep-INDIGO world (Loomlings lesson: cohesion + restraint, no muddy brown)
C.asphalt    = Color3.fromRGB(72, 74, 122)    -- road: clean mid-indigo, reads a step lighter than the board
C.asphaltD   = Color3.fromRGB(48, 50, 92)
C.roadEdge   = Color3.fromRGB(120, 128, 196)  -- cool soft road edge
C.lanePaint  = Color3.fromRGB(196, 206, 245)  -- clean light dashes
C.roadShadow = Color3.fromRGB(14, 14, 30)
C.groundTop  = Color3.fromRGB(54, 52, 98)     -- clean deep-indigo tabletop (cohesive, bright enough to read)
C.groundBot  = Color3.fromRGB(33, 31, 66)     -- darker indigo near the rim
C.pad        = Color3.fromRGB(74, 70, 128)    -- clean indigo tile under a placed tower
C.groundEdge = Color3.fromRGB(104, 100, 168)  -- clean indigo rim
C.skyTop     = Color3.fromRGB(34, 30, 66)      -- deep purple sky top
C.skyBot     = Color3.fromRGB(72, 52, 104)     -- purple horizon (cohesive, NOT warm sunset)
C.silhouette = Color3.fromRGB(28, 26, 56)      -- distant silhouettes read against the purple
C.glow       = Color3.fromRGB(96, 88, 168)     -- cool focal glow at board centre
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

local UI = require(game:GetService("ReplicatedStorage"):WaitForChild("UIEngine")) -- the GUI ENGINE (standalone framework)

-- ===== root =====
local gui = Instance.new("ScreenGui")
gui.Name = "NeonGauntlet"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 60; gui.Parent = pg

local root = frame(gui, "Root") -- shaken as a whole for screen-shake
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = C.ink
local bgGrad = Instance.new("UIGradient")
bgGrad.Rotation = 90
bgGrad.Color = ColorSequence.new(Color3.fromRGB(40, 30, 70), Color3.fromRGB(14, 11, 28)) -- cohesive deep purple
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
-- control points (the coarse path); the actual WAYPOINTS are a smooth Catmull-Rom
-- resample of these so the lane FLOWS instead of zig-zagging between hard corners
local CTRL = {
	Vector2.new(0.5, 0.06), Vector2.new(0.78, 0.16), Vector2.new(0.80, 0.40),
	Vector2.new(0.55, 0.50), Vector2.new(0.22, 0.44), Vector2.new(0.20, 0.68),
	Vector2.new(0.45, 0.80), Vector2.new(0.72, 0.82), Vector2.new(0.5, 0.94),
}
local function crPoint(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: number): Vector2
	local t2, t3 = t * t, t * t * t
	return (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5
end
local WAYPOINTS = {}
do
	local SUB = 6 -- subdivisions per control span
	for i = 1, #CTRL - 1 do
		local p0 = CTRL[math.max(i - 1, 1)]
		local p1, p2 = CTRL[i], CTRL[i + 1]
		local p3 = CTRL[math.min(i + 2, #CTRL)]
		local lastSpan = (i == #CTRL - 1)
		for s = 0, (lastSpan and SUB or SUB - 1) do
			table.insert(WAYPOINTS, crPoint(p0, p1, p2, p3, s / SUB))
		end
	end
end
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
	-- atmospheric FOG BAND at the horizon (warm haze fading up over the hills) = diorama depth cue
	local fog = frame(sky, "Fog"); fog.AnchorPoint = Vector2.new(0.5, 1)
	fog.Position = UDim2.fromScale(0.5, horizon + 0.03); fog.Size = UDim2.fromScale(1, 0.3); fog.ZIndex = 1
	fog.BackgroundColor3 = Color3.fromRGB(108, 84, 150)
	local fgr = Instance.new("UIGradient"); fgr.Rotation = 90
	fgr.Color = ColorSequence.new(Color3.fromRGB(126, 96, 170), Color3.fromRGB(84, 62, 122))
	fgr.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.45) })
	fgr.Parent = fog
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
-- warm FOCAL LIGHT POOL at the board center: brightens the action, funnels the eye (focal hierarchy)
local pool = frame(board, "FocalPool"); pool.AnchorPoint = Vector2.new(0.5, 0.5)
pool.Position = UDim2.fromScale(0.5, 0.44); pool.Size = UDim2.fromScale(0.78, 0.66)
pool.BackgroundColor3 = C.glow; pool.BackgroundTransparency = 0.8; pool.ZIndex = 1
corner(pool, 999)
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
local ROAD = { W = 34 } -- road width in px (constant); lengths stay board-SCALE
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
local function chain(wpx: number, col: Color3, z: number, off: number?, skipJoints: boolean?): { Frame }
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
	if not skipJoints then
		for i = 1, #WAYPOINTS do
			local j = ribbonJoint(WAYPOINTS[i], wpx, col, z); nudge(j); table.insert(pieces, j)
		end
	end
	return pieces
end
local PATH = {
	glow = Color3.fromRGB(86, 150, 255), body = Color3.fromRGB(44, 56, 122),
	rail = Color3.fromRGB(96, 120, 224), core = Color3.fromRGB(176, 216, 255),
	pulse = Color3.fromRGB(226, 240, 255),
}
local flowPulses: { any } = {}
local gameClock = 0
local function drawRoad()
	-- soft wide GLOW halo so the lane reads as flowing energy off the dark board
	for _, pc in chain(ROAD.W + 24, PATH.glow, 1) do pc.BackgroundTransparency = 0.8 end
	-- BODY: deep channel (solid, dark enough that tokens + enemies pop off it)
	for _, pc in chain(ROAD.W, PATH.body, 2) do end
	-- inner RAIL: a narrower lighter band => a beveled tube read, no per-seg gradients
	for _, pc in chain(ROAD.W - 13, PATH.rail, 3) do pc.BackgroundTransparency = 0.14 end
	-- CORE seam: bright thin glowing centerline (segments only, no joint beads)
	for _, pc in chain(6, PATH.core, 4, nil, true) do pc.BackgroundTransparency = 0.4 end
	-- FLOW pulses: bright glowing dots gliding toward the Core = directional juice
	for i = 1, 6 do
		local pulse = frame(board, "Flow"); pulse.AnchorPoint = Vector2.new(0.5, 0.5)
		pulse.Size = UDim2.new(0, 14, 0, 14); pulse.BackgroundColor3 = PATH.pulse; pulse.ZIndex = 6
		corner(pulse, 999); UI.fx.glow(pulse, PATH.core)
		table.insert(flowPulses, { f = pulse, t = (i - 1) / 6 })
	end
end
drawRoad()
RunService.Heartbeat:Connect(function(dt)
	gameClock += dt
	for _, fp in flowPulses do
		fp.t += dt * 0.11
		if fp.t > 1 then fp.t -= 1 end
		local p = pathPos(fp.t)
		fp.f.Position = UDim2.fromScale(p.X, p.Y)
	end
end)

-- Core at the end of the track
local coreP = pathPos(1)
local coreNode = cel(board, C.core, 12)
coreNode.AnchorPoint = Vector2.new(0.5, 0.5)
coreNode.Position = UDim2.fromScale(coreP.X, coreP.Y)
coreNode.Size = UDim2.fromScale(0.12, 0.05)
coreNode.ZIndex = 7
text(coreNode, "\u{6838}", 20, C.ink0).Size = UDim2.fromScale(1, 1)
-- core focal pulse: a breathing glow so the thing you defend reads as the stakes (focal hierarchy)
local coreGlow = frame(board, "CoreGlow"); coreGlow.AnchorPoint = Vector2.new(0.5, 0.5)
coreGlow.Position = UDim2.fromScale(coreP.X, coreP.Y); coreGlow.Size = UDim2.fromScale(0.17, 0.1)
coreGlow.BackgroundColor3 = C.core; coreGlow.BackgroundTransparency = 0.58; coreGlow.ZIndex = 6
corner(coreGlow, 999)
TweenService:Create(coreGlow, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ BackgroundTransparency = 0.86, Size = UDim2.fromScale(0.22, 0.13) }):Play()

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

-- glassy translucent panel: warm-dark fill + top-lit gradient + a light "glass lip" rim + drop shadow
local function glass(parent: Instance, name: string): Frame
	local sh = frame(parent, name .. "Shadow")
	sh.BackgroundColor3 = Color3.new(0, 0, 0); sh.BackgroundTransparency = 0.55; sh.ZIndex = 30
	corner(sh, 12)
	local g = frame(parent, name)
	g.BackgroundColor3 = Color3.fromRGB(24, 26, 36); g.BackgroundTransparency = 0.1; g.ZIndex = 31
	corner(g, 11); stroke(g, Color3.fromRGB(126, 138, 170), 1, 0.45)
	local grad = Instance.new("UIGradient"); grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.fromRGB(54, 58, 78), Color3.fromRGB(18, 20, 28)); grad.Parent = g
	-- keep the shadow glued 3px below/behind the panel
	local function sync()
		sh.Size = g.Size + UDim2.fromOffset(2, 2)
		sh.AnchorPoint = g.AnchorPoint
		sh.Position = g.Position + UDim2.fromOffset(0, 3)
	end
	g:GetPropertyChangedSignal("Size"):Connect(sync); g:GetPropertyChangedSignal("Position"):Connect(sync); sync()
	return g
end

-- ===== HUD =====
local hud = frame(root, "HUD"); hud.BackgroundTransparency = 1; hud.Size = UDim2.new(1, 0, 0, 140); hud.ZIndex = 100
hud.Position = UDim2.fromOffset(0, 52) -- push clear of the Roblox CoreGui topbar (corner icons occlude)
-- centered wave banner (premium Panel)
local waveChip = UI.Panel({ name = "WaveChip", parent = hud, anchor = Vector2.new(0.5, 0), pos = UDim2.fromOffset(0, 4),
	size = UDim2.fromOffset(228, 52), radius = UI.T.radius.pill, fill = UI.T.color.surface, accent = "cyan", shadow = "md", z = 101 })
local waveT = Instance.new("TextLabel"); waveT.BackgroundTransparency = 1; waveT.Font = UI.T.font.display; waveT.Text = "WAVE 1"
waveT.TextSize = UI.T.tsize.xl; waveT.TextColor3 = UI.T.color.cyan; waveT.Size = UDim2.fromScale(1, 1); waveT.ZIndex = 104; waveT.Parent = waveChip
UI.fx.textOutline(waveT, UI.T.color.ink, 3)
waveChip.Position = UDim2.new(0.5, 0, 0, 4)
-- lives + currency pills (icon + value, laid out by the engine)
local lifeChip, lifeText = UI.Pill({ name = "LifeChip", parent = hud, pos = UDim2.fromOffset(26, 6), size = UDim2.fromOffset(110, 52),
	icon = "\u{2665}", iconColor = UI.T.color.danger, value = "5", valueColor = UI.T.color.text, accent = "danger", z = 101 })
local yenChip, yenT = UI.Pill({ name = "YenChip", parent = hud, anchor = Vector2.new(1, 0), pos = UDim2.new(1, -26, 0, 6), size = UDim2.fromOffset(136, 52),
	icon = "\u{00A5}", iconColor = UI.T.color.gold, value = "40", valueColor = UI.T.color.gold, accent = "gold", z = 101 })

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

local function setYen(n: number) state.yen = n; yenT.Text = tostring(n) end
local function setLives(n: number) state.lives = math.max(0, n); lifeText.Text = tostring(state.lives) end
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
		local chip = UI.IconChip({ parent = tray, glyph = def.glyph, glyphColor = UI.T.color.text, glyphSize = UI.T.tsize.lg,
			fill = def.color, accent = def.color, size = UDim2.fromOffset(54, 54), radius = UI.T.radius.md, z = 30 })
		chip.LayoutOrder = i
		local lvl = (RunState.upgrades[id] or 0) + 1
		if lvl > 1 then
			local _, bt = UI.Badge(chip, tostring(lvl), "gold")
			bt.Parent.AnchorPoint = Vector2.new(0.5, 0.5); bt.Parent.Position = UDim2.fromScale(0.92, 0.92); bt.Parent.Size = UDim2.fromOffset(22, 22)
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

-- ===== enemy pool (cute glowing creatures) =====
local function makeEnemy(): any
	local body = frame(board, "Enemy"); body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Size = UDim2.fromOffset(52, 52); body.BackgroundColor3 = C.magenta; body.Visible = false; body.ZIndex = 9
	corner(body, 999)
	local glowFx = UI.fx.glow(body, C.magenta)
	stroke(body, C.white, 1.5, 0.55) -- subtle rim
	-- top sheen (shiny orb highlight, independent of body colour)
	local sheen = frame(body, "Sheen"); sheen.BackgroundColor3 = C.white; sheen.BackgroundTransparency = 0.6
	sheen.AnchorPoint = Vector2.new(0.5, 0.5); sheen.Position = UDim2.fromScale(0.5, 0.26); sheen.Size = UDim2.fromScale(0.6, 0.3); sheen.ZIndex = 10; corner(sheen, 999)
	-- big cute eyes (white + dark pupil + shine)
	for i = 0, 1 do
		local eye = frame(body, "Eye"); eye.BackgroundColor3 = C.white; eye.AnchorPoint = Vector2.new(0.5, 0.5)
		eye.Position = UDim2.fromScale(0.35 + i * 0.3, 0.46); eye.Size = UDim2.fromScale(0.26, 0.32); eye.ZIndex = 11; corner(eye, 999)
		local pupil = frame(eye, "P"); pupil.BackgroundColor3 = Color3.fromRGB(24, 26, 40); pupil.AnchorPoint = Vector2.new(0.5, 0.5)
		pupil.Position = UDim2.fromScale(0.5, 0.6); pupil.Size = UDim2.fromScale(0.55, 0.55); pupil.ZIndex = 12; corner(pupil, 999)
		local shine = frame(pupil, "S"); shine.BackgroundColor3 = C.white; shine.AnchorPoint = Vector2.new(0.5, 0.5)
		shine.Position = UDim2.fromScale(0.34, 0.32); shine.Size = UDim2.fromScale(0.42, 0.42); shine.ZIndex = 13; corner(shine, 999)
	end
	-- HP bar above the head
	local barBg = frame(body, "HPbg"); barBg.AnchorPoint = Vector2.new(0.5, 1); barBg.Position = UDim2.fromScale(0.5, -0.12)
	barBg.Size = UDim2.fromScale(1.15, 0.18); barBg.BackgroundColor3 = C.ink0; barBg.BackgroundTransparency = 0.1; barBg.ZIndex = 11; corner(barBg, 999)
	stroke(barBg, C.ink0, 1, 0.3)
	local bar = frame(barBg, "HP"); bar.AnchorPoint = Vector2.new(0, 0.5); bar.Position = UDim2.fromScale(0.02, 0.5)
	bar.Size = UDim2.fromScale(0.96, 0.62); bar.BackgroundColor3 = C.lime; bar.ZIndex = 12; corner(bar, 999)
	return { body = body, bar = bar, glowFx = glowFx, hp = 0, maxHp = 0, speed = 0, baseSpeed = 0, slowT = 0,
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
	local col = def.boss and C.red or et.color
	e.body.BackgroundColor3 = col
	if e.glowFx then e.glowFx.Color = col end
	local sz = def.boss and 104 or math.floor(52 * et.sizeMul)
	e.body.Size = UDim2.fromOffset(sz, sz)
	e.bar.Size = UDim2.fromScale(0.96, 0.62)
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
	e.bar.Size = UDim2.fromScale(0.96 * math.clamp(e.hp / e.maxHp, 0, 1), 0.62)
	local sx, sy = pxOf(Vector2.new(pathPos(e.progress).X, pathPos(e.progress).Y))
	critNumber(sx, sy, dmg, crit, FIGHTERS[id].color)
	hitSpark(sx, sy, FIGHTERS[id].color)
	if crit then hitStop(0.06); screenShake(4, 3) end
	if e.hp <= 0 and e.active then
		local reward = e.boss and 120 or 5
		setYen(state.yen + reward)
		e.active = false; e.dying = true
		hitSpark(sx, sy, C.white)
		TweenService:Create(e.body, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Size = UDim2.fromOffset(0, 0), Rotation = 40 }):Play()
		task.delay(0.18, function() e.body.Visible = false; e.body.Rotation = 0; e.dying = false; local i = table.find(state.enemies, e); if i then table.remove(state.enemies, i) end end)
		if e.boss then banner("BOSS SLAIN", C.gold); screenFlash(C.gold, 0.4); speedLines() end
	end
end

-- ===== 3D tower viewports (Parts only, no uploads) =====
local rad = math.rad
-- MODELS: id -> { accent, parts = { {shape,size,off, rotY?,tilt?, material,color, neon?,light?}, ... } }
local MODELS = {
	-- Loomlings lesson: SIMPLE + CUTE + one confident class colour. A round creature body + eyes +
	-- ONE clear class prop reads better than an 18-part warrior. ~9 parts each.
	Ronin = { accent = C.cyan, parts = {
		{ "Ball", Vector3.new(2.7,2.6,2.5), Vector3.new(0,1.5,0),      "SmoothPlastic", Color3.fromRGB(72,160,190) }, -- round body (cyan)
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(-0.66,0.4,0.25), "SmoothPlastic", Color3.fromRGB(56,132,160) }, -- foot L
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(0.66,0.4,0.25),  "SmoothPlastic", Color3.fromRGB(56,132,160) }, -- foot R
		{ "Ball", Vector3.new(1.9,1.1,1.7), Vector3.new(0,2.55,-0.05),  "SmoothPlastic", Color3.fromRGB(34,38,58) }, -- dark kabuto cap
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(-0.5,1.78,1.02), "SmoothPlastic", Color3.fromRGB(22,24,36) }, -- eye L
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(0.5,1.78,1.02),  "SmoothPlastic", Color3.fromRGB(22,24,36) }, -- eye R
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(-0.58,1.94,1.17), "SmoothPlastic", Color3.fromRGB(240,248,255) }, -- eye shine L
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(0.42,1.94,1.17),  "SmoothPlastic", Color3.fromRGB(240,248,255) }, -- eye shine R
		{ "Block", Vector3.new(0.14,2.5,0.14), Vector3.new(1.55,2.15,0.2), "Neon", Color3.fromRGB(53,230,255), tilt = Vector3.new(0,0,-22), light = true }, -- glowing katana
	}},
	Onmyoji = { accent = Color3.fromRGB(130,220,235), parts = {
		{ "Ball", Vector3.new(2.7,2.6,2.5), Vector3.new(0,1.5,0),      "SmoothPlastic", Color3.fromRGB(152,202,224) }, -- ice body
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(-0.66,0.4,0.25), "SmoothPlastic", Color3.fromRGB(126,176,200) },
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(0.66,0.4,0.25),  "SmoothPlastic", Color3.fromRGB(126,176,200) },
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(-0.5,1.78,1.02), "SmoothPlastic", Color3.fromRGB(30,40,60) },
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(0.5,1.78,1.02),  "SmoothPlastic", Color3.fromRGB(30,40,60) },
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(-0.58,1.94,1.17), "SmoothPlastic", Color3.fromRGB(240,248,255) },
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(0.42,1.94,1.17),  "SmoothPlastic", Color3.fromRGB(240,248,255) },
		{ "Cylinder", Vector3.new(0.26,2.1,2.1), Vector3.new(0,2.85,0), "SmoothPlastic", Color3.fromRGB(40,46,78), tilt = Vector3.new(0,0,90) }, -- hat brim disc
		{ "Cylinder", Vector3.new(1.6,1.0,1.0), Vector3.new(0,3.75,0), "SmoothPlastic", Color3.fromRGB(48,54,90), tilt = Vector3.new(0,0,90) }, -- hat crown
		{ "Ball", Vector3.new(0.72,0.72,0.72), Vector3.new(1.45,2.25,0.5), "Neon", Color3.fromRGB(130,220,235), light = true }, -- floating ice orb
	}},
	Archer = { accent = C.violet, parts = {
		{ "Ball", Vector3.new(2.7,2.6,2.5), Vector3.new(0,1.5,0),      "SmoothPlastic", Color3.fromRGB(150,120,210) }, -- violet body
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(-0.66,0.4,0.25), "SmoothPlastic", Color3.fromRGB(126,100,180) },
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(0.66,0.4,0.25),  "SmoothPlastic", Color3.fromRGB(126,100,180) },
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(-0.5,1.78,1.02), "SmoothPlastic", Color3.fromRGB(28,26,44) },
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(0.5,1.78,1.02),  "SmoothPlastic", Color3.fromRGB(28,26,44) },
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(-0.58,1.94,1.17), "SmoothPlastic", Color3.fromRGB(240,248,255) },
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(0.42,1.94,1.17),  "SmoothPlastic", Color3.fromRGB(240,248,255) },
		{ "Block", Vector3.new(2.5,0.34,2.35), Vector3.new(0,2.45,0), "SmoothPlastic", Color3.fromRGB(96,64,158) }, -- headband
		{ "Block", Vector3.new(0.16,1.5,0.28), Vector3.new(1.5,2.55,0.25), "SmoothPlastic", Color3.fromRGB(92,66,50), tilt = Vector3.new(24,0,0) }, -- bow upper limb
		{ "Block", Vector3.new(0.16,1.5,0.28), Vector3.new(1.5,1.55,0.25), "SmoothPlastic", Color3.fromRGB(92,66,50), tilt = Vector3.new(-24,0,0) }, -- bow lower limb
		{ "Cylinder", Vector3.new(2.5,0.07,0.07), Vector3.new(1.5,2.05,0.42), "Neon", Color3.fromRGB(168,120,255), light = true }, -- glowing bowstring
	}},
	Monk = { accent = C.gold, parts = {
		{ "Ball", Vector3.new(2.7,2.6,2.5), Vector3.new(0,1.5,0),      "SmoothPlastic", Color3.fromRGB(234,170,88) }, -- gold body
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(-0.66,0.4,0.25), "SmoothPlastic", Color3.fromRGB(206,146,70) },
		{ "Ball", Vector3.new(0.82,0.7,0.82), Vector3.new(0.66,0.4,0.25),  "SmoothPlastic", Color3.fromRGB(206,146,70) },
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(-0.5,1.78,1.02), "SmoothPlastic", Color3.fromRGB(60,36,18) },
		{ "Ball", Vector3.new(0.46,0.58,0.3), Vector3.new(0.5,1.78,1.02),  "SmoothPlastic", Color3.fromRGB(60,36,18) },
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(-0.58,1.94,1.17), "SmoothPlastic", Color3.fromRGB(255,250,240) },
		{ "Ball", Vector3.new(0.17,0.21,0.14), Vector3.new(0.42,1.94,1.17),  "SmoothPlastic", Color3.fromRGB(255,250,240) },
		{ "Block", Vector3.new(1.0,0.55,0.22), Vector3.new(0.35,1.6,1.0), "SmoothPlastic", Color3.fromRGB(196,96,52), rotY = -18 }, -- kesa sash strip across the body
		{ "Cylinder", Vector3.new(0.13,1.6,1.6), Vector3.new(0,3.25,0), "Neon", Color3.fromRGB(255,209,92), tilt = Vector3.new(0,0,90), light = true }, -- gold halo above head
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
	local frameH = 3.5 -- bigger: the round creature fills the card (Loomlings-style prominence)
	local dist = (frameH * 0.5) / math.tan(halfFov)
	local el, az = rad(10), rad(18) -- gentle look-up, slight 3/4 so the side prop separates from the body
	local h = math.cos(el)
	local offset = Vector3.new(h * math.sin(az), math.sin(el), h * math.cos(az)) -- +Z side => we see the FACE
	local target = Vector3.new(0, 1.95, 0)
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
	node.frame.BackgroundTransparency = 1 -- the clean token IS the tower now (no pad card)
	-- clean premium TOKEN via the engine: class-colored circle chip + kanji glyph + soft glow
	local chip = UI.IconChip({ parent = node.frame, name = "Token", glyph = def.glyph, glyphColor = UI.T.color.text,
		glyphSize = UI.T.tsize.xl, fill = def.color, accent = def.color, glow = def.color,
		size = UDim2.fromOffset(76, 76), radius = UI.T.radius.pill, anchor = Vector2.new(0.5, 0.5), pos = UDim2.fromScale(0.5, 0.5), z = 15 })
	local _, badgeT = UI.Badge(chip, tostring((RunState.upgrades[id] or 0) + 1), "gold")
	badgeT.Parent.AnchorPoint = Vector2.new(0.5, 0.5); badgeT.Parent.Position = UDim2.fromScale(0.9, 0.92); badgeT.Parent.ZIndex = 22
	local tw = { id = id, node = node, cd = 0, frame = chip, badge = badgeT }
	node.tower = tw; table.insert(state.towers, tw)
	button(chip).MouseButton1Click:Connect(function()
		-- inspect: expand a range ring
		local S = fStats(id)
		local ring = frame(node.frame, "Ring"); ring.BackgroundTransparency = 1; ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(0.5, 0.5); ring.Size = UDim2.fromScale(0.6, 0.6); ring.ZIndex = 9
		UI.fx.corner(ring, 999); local rst = UI.fx.stroke(ring, def.color, 3, 0.2)
		local r = math.clamp(S.range * 20, 3.5, 9)
		TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(r, r) }):Play()
		TweenService:Create(rst, TweenInfo.new(0.45), { Transparency = 1 }):Play()
		task.delay(0.5, function() ring:Destroy() end)
	end)
	UI.motion.pop(chip)
	hitSpark(select(1, pxOf(node.pos)), select(2, pxOf(node.pos)), def.color)
end
-- keep the level badges in sync when a fighter's tier changes (drafted trait)
local function updateTowerBadges()
	for _, tw in state.towers do
		if tw.badge then tw.badge.Text = tostring((RunState.upgrades[tw.id] or 0) + 1) end
	end
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
				local bob = math.sin(gameClock * 7 + e.progress * 34) * 0.007
				e.body.Position = UDim2.new(p.X, 0, p.Y + bob, 0)
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
		RunState.upgrades[c.id] = (RunState.upgrades[c.id] or 0) + 1
		updateTowerBadges()
	elseif c.kind == "eco" then setYen(state.yen + 40) end
	refreshTray()
end
local function showDraft()
	state.drafting = true
	local drawn = draftCards()
	local scrim = UI.create("Frame", { Name = "Draft", Parent = root, BackgroundColor3 = UI.T.color.overlay,
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = UI.T.z.modal }) :: Frame
	TweenService:Create(scrim, UI.T.motion.base, { BackgroundTransparency = 0.42 }):Play()
	local title = Instance.new("TextLabel"); title.BackgroundTransparency = 1; title.Font = UI.T.font.display
	title.Text = "FORGE YOUR CLASS"; title.TextSize = UI.T.tsize.xxl; title.TextColor3 = UI.T.color.cyan
	title.Size = UDim2.fromScale(1, 0.1); title.Position = UDim2.fromScale(0, 0.13); title.ZIndex = UI.T.z.modal + 1; title.Parent = scrim
	UI.fx.textOutline(title, UI.T.color.ink, 4)
	local done = false
	local function choose(c: any)
		if done then return end; done = true; applyCard(c)
		TweenService:Create(scrim, UI.T.motion.fast, { BackgroundTransparency = 1 }):Play()
		task.delay(0.16, function() scrim:Destroy() end); state.drafting = false
	end
	local xs = { 0.24, 0.5, 0.76 }
	for i, c in drawn do
		local accent = c.color
		local card = UI.Card({ parent = scrim, size = UDim2.fromOffset(250, 384), anchor = Vector2.new(0.5, 0.5),
			pos = UDim2.fromScale(xs[i] or 0.5, 0.55), accent = accent, glow = accent, z = UI.T.z.modal + 2 })
		local ic = UI.IconChip({ parent = card.body, glyph = c.glyph, glyphColor = UI.T.color.text, glyphSize = UI.T.tsize.hero,
			fill = accent, accent = accent, size = UDim2.fromOffset(100, 100), radius = UI.T.radius.lg, z = UI.T.z.modal + 3 })
		ic.LayoutOrder = 1
		local nm = Instance.new("TextLabel"); nm.BackgroundTransparency = 1; nm.Font = UI.T.font.heading; nm.Text = c.title
		nm.TextSize = UI.T.tsize.md; nm.TextColor3 = accent; nm.Size = UDim2.new(1, 0, 0, 44); nm.TextWrapped = true
		nm.LayoutOrder = 2; nm.ZIndex = UI.T.z.modal + 3; nm.Parent = card.body
		local tp = Instance.new("TextLabel"); tp.BackgroundTransparency = 1; tp.Font = UI.T.font.med; tp.Text = c.tip
		tp.TextSize = UI.T.tsize.sm; tp.TextColor3 = UI.T.color.textMid; tp.Size = UDim2.new(1, 0, 0, 40); tp.TextWrapped = true
		tp.LayoutOrder = 3; tp.ZIndex = UI.T.z.modal + 3; tp.Parent = card.body
		local btn = UI.Button({ parent = card.footer, text = "CHOOSE", accent = accent, size = UDim2.new(1, 0, 0, 42), z = UI.T.z.modal + 3 })
		btn.MouseButton1Click:Connect(function() choose(c) end)
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
	local scrim = UI.create("Frame", { Name = "Over", Parent = root, BackgroundColor3 = UI.T.color.overlay,
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = UI.T.z.modal + 10 }) :: Frame
	TweenService:Create(scrim, UI.T.motion.base, { BackgroundTransparency = 0.28 }):Play()
	local card = UI.Card({ parent = scrim, size = UDim2.fromOffset(420, 330), accent = "danger", glow = "danger", z = UI.T.z.modal + 11 })
	local big = Instance.new("TextLabel"); big.BackgroundTransparency = 1; big.Font = UI.T.font.display; big.Text = "OVERRUN"
	big.TextSize = UI.T.tsize.hero; big.TextColor3 = UI.T.color.danger; big.Size = UDim2.new(1, 0, 0, 64); big.LayoutOrder = 1; big.ZIndex = UI.T.z.modal + 12; big.Parent = card.body
	UI.fx.textOutline(big, UI.T.color.ink, 4)
	local sub = Instance.new("TextLabel"); sub.BackgroundTransparency = 1; sub.Font = UI.T.font.body; sub.Text = "You held to WAVE " .. state.wave
	sub.TextSize = UI.T.tsize.lg; sub.TextColor3 = UI.T.color.text; sub.Size = UDim2.new(1, 0, 0, 30); sub.LayoutOrder = 2; sub.ZIndex = UI.T.z.modal + 12; sub.Parent = card.body
	local btn = UI.Button({ parent = card.footer, text = "RUN IT BACK", accent = "cyan", size = UDim2.new(1, 0, 0, 44), z = UI.T.z.modal + 12 })
	btn.MouseButton1Click:Connect(function()
		gui:Destroy(); if hbConn then hbConn:Disconnect() end
		local clone = script:Clone(); clone.Parent = script.Parent; clone.Disabled = false
	end)
	if DEBUG.autoPlay then task.delay(2.5, function() btn.MouseButton1Click:Fire() end) end
end

print("[NeonGauntlet] ready")
