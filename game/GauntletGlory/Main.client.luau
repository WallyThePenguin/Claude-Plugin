--!strict
-- GAUNTLET & GLORY — GUI-only one-life roguelite tower-defense + duel.
-- One client LocalScript builds the whole UI and runs the game (no meshes/parts/DataStore).
-- Loop: survive the infinite one-life TD -> the towers/upgrades you draft FORGE a Champion ->
-- duel that Champion vs a house Champion. Modularizes as it grows; today it's one focused file.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- DEBUG auto-driver: lets the game be verified headlessly (no clicks available in a capture).
-- autoPlay places towers + picks drafts; pauseOnDraft keeps a draft on screen long enough to
-- capture; forceDeathWave forces the run to end so the forge/duel screens can be verified.
local DEBUG = { autoPlay = false, pauseOnDraft = 0, forceDeathWave = 0 }

-- ===== Theme =====
local Theme = {
	bg = Color3.fromRGB(14, 16, 20),
	panel = Color3.fromRGB(22, 26, 33),
	panelHi = Color3.fromRGB(34, 40, 51),
	lane = Color3.fromRGB(18, 21, 27),
	accent = Color3.fromRGB(94, 160, 255),
	gold = Color3.fromRGB(255, 205, 90),
	danger = Color3.fromRGB(255, 84, 96),
	core = Color3.fromRGB(120, 235, 190),
	text = Color3.fromRGB(232, 238, 246),
	textDim = Color3.fromRGB(140, 150, 165),
	enemy = Color3.fromRGB(226, 96, 110),
	elite = Color3.fromRGB(196, 120, 255),
	font = Enum.Font.GothamBold,
	fontBlack = Enum.Font.GothamBlack,
}

local function corner(p: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
	return c
end
local function stroke(p: Instance, color: Color3, th: number, tr: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = th
	s.Transparency = tr or 0
	s.Parent = p
	return s
end
local function frame(parent: Instance, name: string?): Frame
	local f = Instance.new("Frame")
	f.Name = name or "F"
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Theme.panel
	f.Parent = parent
	return f
end
local function text(parent: Instance, s: string, size: number, color: Color3?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Theme.font
	t.Text = s
	t.TextSize = size
	t.TextColor3 = color or Theme.text
	t.Parent = parent
	return t
end
local function button(parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.BackgroundTransparency = 1
	b.Text = ""
	b.AutoButtonColor = false
	b.Size = UDim2.fromScale(1, 1)
	b.Parent = parent
	return b
end

-- ===== Tower definitions (SINGLE source: TD stats + tags + duel-ability mapping + tooltips) =====
type TowerDef = {
	id: string, name: string, color: Color3, glyph: string, tag: string,
	damage: number, fireRate: number, range: number, slow: number,
	cost: number, ability: string, abilityDesc: string, gauntlet: string, arena: string,
}
local TOWERS: { [string]: TowerDef } = {
	Cannon = { id = "Cannon", name = "Cannon", color = Color3.fromRGB(120, 200, 255), glyph = "\u{25C9}", tag = "Kinetic",
		damage = 12, fireRate = 0.85, range = 0.24, slow = 0, cost = 15,
		ability = "Slug", abilityDesc = "A heavy single-target blow.",
		gauntlet = "Hard single hits", arena = "High-damage nuke" },
	Splinter = { id = "Splinter", name = "Splinter", color = Color3.fromRGB(180, 240, 120), glyph = "\u{2726}", tag = "Rapid",
		damage = 5, fireRate = 0.32, range = 0.20, slow = 0, cost = 18,
		ability = "Barrage", abilityDesc = "A flurry of fast light hits.",
		gauntlet = "Fast, weak, rapid fire", arena = "Rapid multi-hit combo" },
	Frost = { id = "Frost", name = "Frost", color = Color3.fromRGB(130, 220, 235), glyph = "\u{2744}", tag = "Cold",
		damage = 7, fireRate = 0.7, range = 0.26, slow = 0.4, cost = 20,
		ability = "Frostbite", abilityDesc = "Chip damage that slows the foe.",
		gauntlet = "Slows enemies + chip", arena = "Slows their cooldowns" },
}
local START_TOWER = "Cannon"

-- ===== Root =====
local gui = Instance.new("ScreenGui")
gui.Name = "GauntletGlory"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 50
gui.Parent = playerGui

local bg = frame(gui, "BG")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Theme.bg

local lane = frame(bg, "Lane")
lane.AnchorPoint = Vector2.new(0.5, 0.5)
lane.Position = UDim2.fromScale(0.5, 0.52)
lane.Size = UDim2.fromScale(0.26, 0.82)
lane.BackgroundColor3 = Theme.lane
corner(lane, 14)
stroke(lane, Theme.panelHi, 2, 0.2)
do
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(Color3.fromRGB(24, 28, 36), Color3.fromRGB(15, 17, 22))
	g.Parent = lane
end

local core = frame(lane, "Core")
core.AnchorPoint = Vector2.new(0.5, 1)
core.Position = UDim2.fromScale(0.5, 1)
core.Size = UDim2.new(1, -8, 0, 14)
core.BackgroundColor3 = Theme.core
corner(core, 7)
stroke(core, Theme.core, 3, 0.3)

type Slot = { frame: Frame, side: number, y: number, tower: any, plus: TextLabel, btn: TextButton }
local slots: { Slot } = {}
for side = 0, 1 do
	for i = 0, 3 do
		local yScale = 0.13 + (i / 3) * 0.64
		local s = frame(lane, "Slot")
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Size = UDim2.fromScale(0.30, 0.095)
		s.Position = UDim2.fromScale(side == 0 and -0.06 or 1.06, yScale)
		s.BackgroundColor3 = Theme.panel
		s.BackgroundTransparency = 0.12
		corner(s, 10)
		stroke(s, Theme.panelHi, 2, 0.3)
		local plus = text(s, "+", 22, Theme.textDim)
		plus.Size = UDim2.fromScale(1, 1)
		local btn = button(s)
		table.insert(slots, { frame = s, side = side, y = yScale, tower = nil, plus = plus, btn = btn })
	end
end

-- ===== HUD =====
local hud = frame(bg, "HUD")
hud.BackgroundTransparency = 1
hud.Size = UDim2.new(1, 0, 0, 56)

local waveLabel = text(hud, "WAVE 1", 24, Theme.text)
waveLabel.Font = Theme.fontBlack
waveLabel.AnchorPoint = Vector2.new(0.5, 0)
waveLabel.Position = UDim2.fromScale(0.5, 0.2)
waveLabel.Size = UDim2.fromScale(0.5, 0.6)

local coinLabel = text(hud, "0", 22, Theme.gold)
coinLabel.AnchorPoint = Vector2.new(1, 0)
coinLabel.Position = UDim2.new(1, -20, 0, 14)
coinLabel.Size = UDim2.fromScale(0.25, 0.5)
coinLabel.TextXAlignment = Enum.TextXAlignment.Right

-- Build tray: shows your growing class (owned tower types) down the left edge.
local tray = frame(bg, "Tray")
tray.BackgroundTransparency = 1
tray.AnchorPoint = Vector2.new(0, 0.5)
tray.Position = UDim2.fromScale(0.02, 0.52)
tray.Size = UDim2.fromScale(0.1, 0.5)
local trayLayout = Instance.new("UIListLayout")
trayLayout.Padding = UDim.new(0, 8)
trayLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
trayLayout.SortOrder = Enum.SortOrder.LayoutOrder
trayLayout.Parent = tray
local trayTitle = text(tray, "CLASS", 13, Theme.textDim)
trayTitle.Size = UDim2.new(1, 0, 0, 16)
trayTitle.LayoutOrder = 0

local dbg = text(bg, "", 14, Color3.fromRGB(255, 120, 120))
dbg.Position = UDim2.fromScale(0.01, 0.9)
dbg.Size = UDim2.fromScale(0.35, 0.05)
dbg.TextXAlignment = Enum.TextXAlignment.Left
dbg.ZIndex = 90
dbg.Visible = DEBUG.autoPlay -- dev readout only; hidden in real play

local banner = text(bg, "", 44, Theme.accent)
banner.Font = Theme.fontBlack
banner.AnchorPoint = Vector2.new(0.5, 0.5)
banner.Position = UDim2.fromScale(0.5, 0.32)
banner.Size = UDim2.fromScale(0.8, 0.12)
banner.TextTransparency = 1

-- ===== State + RunState =====
local RunState = {
	owned = { [START_TOWER] = true } :: { [string]: boolean },
	up = { [START_TOWER] = { dmg = 0, rate = 0 } } :: { [string]: { dmg: number, rate: number } },
	perks = {} :: { string },
	dmgByType = { [START_TOWER] = 0 } :: { [string]: number },
	wavesSurvived = 0,
	coinBonus = 0,
	globalDmg = 0,
}
local state = {
	wave = 0, coins = 40, alive = true, drafting = false,
	started = (_G :: any).GGStarted == true, -- skip the title on a NEW RUN restart (same session)
	enemies = {} :: { any }, spawnQueue = {} :: { any }, towers = {} :: { any },
}
local MAX_LIVE = 40

local function setCoins(n: number)
	state.coins = n
	coinLabel.Text = "\u{1FA99} " .. tostring(n)
end
setCoins(state.coins)

local function refreshTray()
	for _, c in tray:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local order = 1
	for id in RunState.owned do
		local def = TOWERS[id]
		local chip = frame(tray, "Chip")
		chip.Size = UDim2.new(0, 44, 0, 44)
		chip.BackgroundColor3 = def.color
		chip.LayoutOrder = order
		corner(chip, 10)
		stroke(chip, Color3.new(1, 1, 1), 1.5, 0.5)
		local g = text(chip, def.glyph, 22, Color3.fromRGB(10, 18, 28))
		g.Size = UDim2.fromScale(1, 1)
		order += 1
	end
end
refreshTray()

-- ===== FeedbackFX =====
local function popup(s: string, ax: number, ay: number, color: Color3)
	local l = text(lane, s, 18, color)
	l.Font = Theme.fontBlack
	l.ZIndex = 20
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(ax, ay)
	l.Size = UDim2.fromScale(0.5, 0.06)
	TweenService:Create(l, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(ax, ay - 0.06), TextTransparency = 1,
	}):Play()
	task.delay(0.6, function() l:Destroy() end)
end
local function flashBanner(s: string, color: Color3)
	banner.Text = s
	banner.TextColor3 = color
	banner.TextTransparency = 0
	banner.Size = UDim2.fromScale(0.5, 0.10)
	TweenService:Create(banner, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.8, 0.12) }):Play()
	task.delay(0.9, function() TweenService:Create(banner, TweenInfo.new(0.4), { TextTransparency = 1 }):Play() end)
end

-- ===== Enemy pool =====
local function makeEnemy(): any
	local f = frame(lane, "Enemy")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromScale(0.34, 0.05)
	f.BackgroundColor3 = Theme.enemy
	f.Visible = false
	f.ZIndex = 8
	corner(f, 9)
	stroke(f, Color3.new(1, 1, 1), 1.5, 0.6)
	local bar = frame(f, "HP")
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 3, 1, -2)
	bar.Size = UDim2.new(1, -6, 0, 3)
	bar.BackgroundColor3 = Color3.fromRGB(120, 255, 150)
	bar.ZIndex = 9
	corner(bar, 2)
	return { frame = f, hp = 0, maxHp = 0, speed = 0, baseSpeed = 0, slowT = 0, progress = 0, active = false, hpbar = bar, elite = false }
end
local pool: { any } = {}
for _ = 1, MAX_LIVE do
	table.insert(pool, makeEnemy())
end
local function acquire(): any?
	for _, e in pool do
		if not e.active and not e.dying then return e end -- don't reuse a frame mid death-pop
	end
	return nil
end
local function release(e: any)
	e.active = false
	e.frame.Visible = false
	local i = table.find(state.enemies, e)
	if i then table.remove(state.enemies, i) end
end

-- ===== Wave director =====
local function schedule(n: number): { any }
	local count = 6 + math.floor(n * 1.6)
	local hp = math.floor(12 * (1.16 ^ n))
	local speed = 0.05 + math.min(n, 30) * 0.0016
	local elite = (n % 5 == 0)
	local list = {}
	for _ = 1, count do
		table.insert(list, { hp = elite and hp * 6 or hp, speed = elite and speed * 0.6 or speed, elite = elite })
	end
	return list
end
local function spawn(def: any)
	local e = acquire()
	if not e then return end
	e.hp = def.hp; e.maxHp = def.hp; e.speed = def.speed; e.baseSpeed = def.speed
	e.slowT = 0; e.elite = def.elite; e.progress = 0; e.active = true
	e.frame.BackgroundColor3 = def.elite and Theme.elite or Theme.enemy
	e.frame.Size = def.elite and UDim2.fromScale(0.5, 0.07) or UDim2.fromScale(0.34, 0.05)
	e.frame.Position = UDim2.fromScale(0.5, 0.05)
	e.hpbar.Size = UDim2.new(1, -6, 0, 3)
	e.frame.Visible = true
	table.insert(state.enemies, e)
end

-- ===== Towers =====
local endRun -- fwd
local function towerStats(id: string): (number, number)
	local def = TOWERS[id]
	local u = RunState.up[id]
	local dmg = (def.damage + (u and u.dmg or 0)) * (1 + RunState.globalDmg)
	local rate = def.fireRate * (1 - (u and u.rate or 0) * 0.06)
	return dmg, math.max(0.12, rate)
end

local ey = function(prog: number): number return 0.05 + prog * 0.86 end

local function fireBolt(fromY: number, side: number, toY: number, color: Color3)
	local b = frame(lane, "Bolt")
	b.BackgroundColor3 = color
	b.ZIndex = 15
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.BackgroundTransparency = 0.1
	corner(b, 2)
	local x0 = side == 0 and 0.06 or 0.94
	local dx, dy = 0.5 - x0, (toY - fromY)
	b.Size = UDim2.fromScale(math.sqrt(dx * dx + dy * dy), 0.008)
	b.Position = UDim2.fromScale((x0 + 0.5) / 2, (fromY + toY) / 2)
	b.Rotation = math.deg(math.atan2(dy, dx))
	TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 1 }):Play()
	task.delay(0.13, function() b:Destroy() end)
end

local function damageEnemy(e: any, dmg: number, typeId: string, atY: number)
	e.hp -= dmg
	RunState.dmgByType[typeId] = (RunState.dmgByType[typeId] or 0) + dmg
	e.hpbar.Size = UDim2.new(math.clamp(e.hp / e.maxHp, 0, 1), -6, 0, 3)
	if e.hp <= 0 and e.active then
		local reward = (e.elite and 30 or 4) + RunState.coinBonus
		setCoins(state.coins + reward)
		popup("+" .. reward, 0.5, atY, Theme.gold)
		e.active = false
		e.dying = true
		local i = table.find(state.enemies, e)
		if i then table.remove(state.enemies, i) end -- leave the active list NOW so waves clear instantly
		TweenService:Create(e.frame, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Size = UDim2.fromScale(0.02, 0.02) }):Play()
		task.delay(0.16, function() e.frame.Visible = false; e.dying = false end)
	end
end

local typePicker -- fwd (defined after draft helpers)
local function upgradeTower(tw: any)
	local def = TOWERS[tw.id]
	local cost = 12 + tw.level * 8
	if state.coins < cost then
		popup("need \u{1FA99}", tw.slot.side == 0 and 0.1 or 0.9, tw.slot.y, Theme.danger)
		return
	end
	setCoins(state.coins - cost)
	tw.level += 1
	tw.dmgBonus += math.ceil(def.damage * 0.5)
	local pip = text(tw.frame, string.rep("\u{2022}", tw.level), 12, Color3.fromRGB(10, 18, 28))
	pip.Name = "Pips"
	pip.AnchorPoint = Vector2.new(0.5, 1)
	pip.Position = UDim2.fromScale(0.5, 1)
	pip.Size = UDim2.fromScale(1, 0.3)
	local old = tw.frame:FindFirstChild("Pips")
	if old and old ~= pip then old:Destroy() end
	popup("LV" .. (tw.level + 1), tw.slot.side == 0 and 0.15 or 0.85, tw.slot.y, def.color)
end

local function placeType(slot: Slot, id: string)
	local def = TOWERS[id]
	if state.coins < def.cost then
		popup("need \u{1FA99}", slot.side == 0 and 0.1 or 0.9, slot.y, Theme.danger)
		return
	end
	setCoins(state.coins - def.cost)
	slot.plus.Visible = false
	local t = frame(slot.frame, "Tower")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = def.color
	t.BackgroundTransparency = 0.05
	corner(t, 10)
	stroke(t, Color3.new(1, 1, 1), 1.5, 0.4)
	local glyph = text(t, def.glyph, 22, Color3.fromRGB(10, 18, 28))
	glyph.Size = UDim2.fromScale(1, 1)
	local tw = { id = id, slot = slot, cd = 0, level = 0, dmgBonus = 0, frame = t }
	slot.tower = tw
	table.insert(state.towers, tw)
	button(t).MouseButton1Click:Connect(function() upgradeTower(tw) end)
	t.Size = UDim2.fromScale(0.4, 0.4)
	TweenService:Create(t, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) }):Play()
end

-- picker: click an empty slot -> choose which OWNED tower type to place
function typePicker(slot: Slot)
	if slot.tower or not state.alive then return end
	local owned = {}
	for id in RunState.owned do table.insert(owned, id) end
	if #owned == 1 then
		placeType(slot, owned[1])
		return
	end
	local menu = frame(bg, "Picker")
	menu.AnchorPoint = Vector2.new(0.5, 0.5)
	menu.Position = UDim2.fromScale(slot.side == 0 and 0.22 or 0.78, slot.y * 0.82 + 0.09)
	menu.Size = UDim2.fromScale(0.14, 0.06 * #owned)
	menu.BackgroundColor3 = Theme.panel
	menu.ZIndex = 40
	corner(menu, 10)
	stroke(menu, Theme.accent, 2, 0.3)
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, 4)
	ll.Parent = menu
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4); pad.PaddingRight = UDim.new(0, 4)
	pad.Parent = menu
	for _, id in owned do
		local def = TOWERS[id]
		local row = frame(menu, "Row")
		row.Size = UDim2.new(1, 0, 0, 34)
		row.BackgroundColor3 = def.color
		row.ZIndex = 41
		corner(row, 8)
		local lbl = text(row, def.glyph .. "  " .. def.name .. "  \u{1FA99}" .. def.cost, 14, Color3.fromRGB(10, 18, 28))
		lbl.ZIndex = 42
		lbl.Size = UDim2.fromScale(1, 1)
		button(row).MouseButton1Click:Connect(function()
			menu:Destroy()
			placeType(slot, id)
		end)
	end
	task.delay(4, function() if menu and menu.Parent then menu:Destroy() end end)
end

for _, slot in slots do
	slot.btn.MouseButton1Click:Connect(function() typePicker(slot) end)
end

-- ===== Heartbeat (one connection) =====
local hbConn: RBXScriptConnection
hbConn = RunService.Heartbeat:Connect(function(dt)
	local act = 0
	for _, e in state.enemies do if e.active then act += 1 end end
	dbg.Text = string.format("e=%d act=%d q=%d w=%d draft=%s alive=%s", #state.enemies, act, #state.spawnQueue, state.wave, tostring(state.drafting), tostring(state.alive))
	if not state.alive or state.drafting then return end
	if #state.spawnQueue > 0 and #state.enemies < MAX_LIVE then
		local def = state.spawnQueue[1]
		def._t = (def._t or 0) + dt
		if def._t >= (def._gap or 0) then
			table.remove(state.spawnQueue, 1)
			spawn(def)
		end
	end
	for i = #state.enemies, 1, -1 do
		local e = state.enemies[i]
		if e.active then
			if e.slowT > 0 then e.slowT -= dt end
			e.speed = e.slowT > 0 and e.baseSpeed * 0.5 or e.baseSpeed
			e.progress += e.speed * dt
			if e.progress >= 0.92 then endRun(); return end
			e.frame.Position = UDim2.fromScale(0.5, ey(e.progress))
		end
	end
	for _, tw in state.towers do
		tw.cd -= dt
		if tw.cd <= 0 then
			local def = TOWERS[tw.id]
			local best, bp = nil, -1
			for _, e in state.enemies do
				if e.active then
					local y = ey(e.progress)
					if math.abs(y - tw.slot.y) <= def.range and e.progress > bp then best, bp = e, e.progress end
				end
			end
			if best then
				local y = ey(best.progress)
				local dmg, rate = towerStats(tw.id)
				dmg += tw.dmgBonus
				fireBolt(tw.slot.y, tw.slot.side, y, def.color)
				if def.slow > 0 then best.slowT = def.slow end
				damageEnemy(best, dmg, tw.id, y)
				tw.cd = rate
			end
		end
	end
end)

-- ===== Draft (between waves) =====
local DRAFT_POOL_ORDER = { "Splinter", "Frost" }
local function buildDraftCards(): { any }
	local cards = {}
	-- offer an unowned tower if any
	for _, id in DRAFT_POOL_ORDER do
		if not RunState.owned[id] then
			local def = TOWERS[id]
			table.insert(cards, { kind = "tower", id = id, title = "NEW: " .. def.name, glyph = def.glyph, color = def.color,
				gauntlet = def.gauntlet, arena = def.arena })
		end
	end
	-- upgrades for owned towers
	for id in RunState.owned do
		local def = TOWERS[id]
		table.insert(cards, { kind = "up", id = id, stat = "dmg", title = def.name .. " +DMG", glyph = "\u{2191}", color = def.color,
			gauntlet = "+damage to " .. def.name, arena = "+ability power" })
		table.insert(cards, { kind = "up", id = id, stat = "rate", title = def.name .. " +SPEED", glyph = "\u{00BB}", color = def.color,
			gauntlet = "faster " .. def.name, arena = "faster cooldowns" })
	end
	-- perks
	table.insert(cards, { kind = "perk", id = "Greed", title = "GREED", glyph = "\u{1FA99}", color = Theme.gold,
		gauntlet = "+2 coins per kill", arena = "start duels with shield" })
	table.insert(cards, { kind = "perk", id = "Fury", title = "FURY", glyph = "\u{1F525}", color = Theme.danger,
		gauntlet = "+12% all tower damage", arena = "+12% ability damage" })
	-- pick 3 distinct at random
	local out = {}
	for _ = 1, 3 do
		if #cards == 0 then break end
		local idx = math.random(1, #cards)
		table.insert(out, cards[idx])
		table.remove(cards, idx)
	end
	return out
end

local function applyCard(c: any)
	if c.kind == "tower" then
		RunState.owned[c.id] = true
		RunState.up[c.id] = { dmg = 0, rate = 0 }
		RunState.dmgByType[c.id] = 0
	elseif c.kind == "up" then
		local u = RunState.up[c.id]
		u[c.stat] = (u[c.stat] or 0) + 1
	elseif c.kind == "perk" then
		table.insert(RunState.perks, c.id)
		if c.id == "Greed" then RunState.coinBonus += 2 end
		if c.id == "Fury" then RunState.globalDmg += 0.12 end
	end
	refreshTray()
end

local runDuel -- fwd (Stage 2)
local function showDraft()
	state.drafting = true
	local drawn = buildDraftCards()
	local ov = frame(bg, "Draft")
	ov.Size = UDim2.fromScale(1, 1)
	ov.BackgroundColor3 = Theme.bg
	ov.BackgroundTransparency = 0.35
	ov.ZIndex = 50
	local title = text(ov, "DRAFT \u{2014} forge your class", 26, Theme.text)
	title.Font = Theme.fontBlack
	title.Position = UDim2.fromScale(0, 0.14)
	title.Size = UDim2.fromScale(1, 0.08)
	title.ZIndex = 51
	local row = frame(ov, "Row")
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.5)
	row.Size = UDim2.fromScale(0.82, 0.5)
	row.ZIndex = 51
	local ll = Instance.new("UIListLayout")
	ll.FillDirection = Enum.FillDirection.Horizontal
	ll.HorizontalAlignment = Enum.HorizontalAlignment.Center
	ll.VerticalAlignment = Enum.VerticalAlignment.Center
	ll.Padding = UDim.new(0, 18)
	ll.Parent = row
	local finished = false
	local function choose(c: any)
		if finished then return end
		finished = true
		applyCard(c)
		ov:Destroy()
		state.drafting = false -- the wave loop unblocks on this and starts the next wave
	end
	for _, c in drawn do
		local card = frame(row, "Card")
		card.Size = UDim2.fromScale(0.28, 1)
		card.BackgroundColor3 = Theme.panel
		card.ZIndex = 52
		corner(card, 14)
		stroke(card, c.color, 2, 0.15)
		local icon = frame(card, "Icon")
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.fromScale(0.5, 0.08)
		icon.Size = UDim2.fromScale(0.4, 0.28)
		icon.BackgroundColor3 = c.color
		icon.ZIndex = 53
		corner(icon, 12)
		local g = text(icon, c.glyph, 30, Color3.fromRGB(10, 18, 28))
		g.Size = UDim2.fromScale(1, 1)
		g.ZIndex = 54
		local nm = text(card, c.title, 18, Theme.text)
		nm.Font = Theme.fontBlack
		nm.Position = UDim2.fromScale(0, 0.42)
		nm.Size = UDim2.fromScale(1, 0.1)
		nm.ZIndex = 53
		local tg = text(card, "\u{2694} Gauntlet: " .. c.gauntlet, 13, Theme.textDim)
		tg.Position = UDim2.fromScale(0.06, 0.58)
		tg.Size = UDim2.fromScale(0.88, 0.1)
		tg.TextWrapped = true
		tg.TextXAlignment = Enum.TextXAlignment.Left
		tg.ZIndex = 53
		local ar = text(card, "\u{1F6E1} Arena: " .. c.arena, 13, Theme.accent)
		ar.Position = UDim2.fromScale(0.06, 0.7)
		ar.Size = UDim2.fromScale(0.88, 0.1)
		ar.TextWrapped = true
		ar.TextXAlignment = Enum.TextXAlignment.Left
		ar.ZIndex = 53
		local b = button(card)
		b.ZIndex = 55
		b.MouseButton1Click:Connect(function() choose(c) end)
		b.MouseEnter:Connect(function()
			TweenService:Create(card, TweenInfo.new(0.12), { Size = UDim2.fromScale(0.30, 1.04) }):Play()
		end)
		b.MouseLeave:Connect(function()
			TweenService:Create(card, TweenInfo.new(0.12), { Size = UDim2.fromScale(0.28, 1) }):Play()
		end)
	end
	if DEBUG.autoPlay then
		task.delay(DEBUG.pauseOnDraft > 0 and DEBUG.pauseOnDraft or 0.5, function()
			if not finished then choose(drawn[1]) end
		end)
	end
end

-- ===== Wave flow =====
local function startWave()
	state.wave += 1
	RunState.wavesSurvived = state.wave
	waveLabel.Text = "WAVE " .. state.wave
	local isElite = state.wave % 5 == 0
	flashBanner(isElite and "ELITE WAVE" or ("WAVE " .. state.wave), isElite and Theme.elite or Theme.accent)
	local gap = math.max(0.35, 0.9 - state.wave * 0.02)
	for _, def in schedule(state.wave) do
		def._gap = gap
		table.insert(state.spawnQueue, def)
	end
end
local function waveClear(): boolean
	if #state.spawnQueue > 0 then return false end
	for _, e in state.enemies do
		if e.active then return false end
	end
	return true
end

task.spawn(function()
	while not state.started and state.alive do
		task.wait(0.05)
	end
	if not state.alive then
		return
	end
	startWave()
	while state.alive do
		task.wait(0.4)
		if state.alive and not state.drafting and waveClear() then
			if DEBUG.forceDeathWave > 0 and state.wave >= DEBUG.forceDeathWave then
				endRun()
				return
			end
			showDraft() -- sets state.drafting = true; resolves (choose) sets it false
			local guard = 0
			while state.drafting and state.alive and guard < 600 do
				task.wait(0.1)
				guard += 1
			end
			if state.alive then
				startWave()
			end
		end
	end
end)

-- DEBUG auto-place towers each frame budget
if DEBUG.autoPlay then
	task.spawn(function()
		while state.alive do
			for _, slot in slots do
				if not slot.tower and state.coins >= 15 and not state.drafting then
					typePicker(slot)
					task.wait(0.15)
				end
			end
			task.wait(0.6)
		end
	end)
end

-- ===== Forge =====
local function forgeChampion(): any
	-- top-4 tower types by damage become abilities; waves set tier; dominant tag = archetype
	local ranked = {}
	for id, dmg in RunState.dmgByType do
		table.insert(ranked, { id = id, dmg = dmg })
	end
	table.sort(ranked, function(a, b) return a.dmg > b.dmg end)
	local abilities = {}
	for i = 1, math.min(4, #ranked) do
		local def = TOWERS[ranked[i].id]
		local u = RunState.up[ranked[i].id] or { dmg = 0, rate = 0 }
		table.insert(abilities, {
			id = def.id, name = def.ability, glyph = def.glyph, color = def.color, tag = def.tag,
			power = math.floor((def.damage + u.dmg) * (1 + RunState.globalDmg) * (1 + u.rate * 0.1) + 6),
			cd = def.fireRate * (def.slow > 0 and 1.6 or 1.2), desc = def.abilityDesc, slow = def.slow,
		})
	end
	local tagCount = {}
	for id in RunState.owned do
		local t = TOWERS[id].tag
		tagCount[t] = (tagCount[t] or 0) + 1
	end
	local domTag, domN = "Kinetic", 0
	for t, n in tagCount do if n > domN then domTag, domN = t, n end end
	local archetype = ({ Kinetic = "Bruiser", Rapid = "Duelist", Cold = "Cryomancer" })[domTag] or "Fighter"
	local tier = RunState.wavesSurvived
	return {
		name = player.DisplayName,
		archetype = archetype,
		tier = tier,
		hp = 80 + tier * 8,
		abilities = abilities,
		hasShield = table.find(RunState.perks, "Greed") ~= nil,
	}
end

-- ===== One-life fail -> forge screen =====
function endRun()
	if not state.alive then return end
	state.alive = false
	local flash = frame(bg, "Flash")
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Theme.danger
	flash.BackgroundTransparency = 0.35
	flash.ZIndex = 60
	TweenService:Create(flash, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
	for _ = 1, 6 do
		bg.Position = UDim2.fromOffset(math.random(-8, 8), math.random(-8, 8))
		task.wait(0.03)
	end
	bg.Position = UDim2.fromScale(0, 0)

	local champ = forgeChampion()
	local ov = frame(bg, "Forge")
	ov.Size = UDim2.fromScale(1, 1)
	ov.BackgroundColor3 = Theme.bg
	ov.BackgroundTransparency = 0.1
	ov.ZIndex = 61
	local h = text(ov, "RUN OVER \u{2014} WAVE " .. state.wave, 22, Theme.danger)
	h.Font = Theme.fontBlack
	h.Position = UDim2.fromScale(0, 0.08)
	h.Size = UDim2.fromScale(1, 0.07)
	h.ZIndex = 62
	local sub = text(ov, "YOU FORGED A CHAMPION", 16, Theme.textDim)
	sub.Position = UDim2.fromScale(0, 0.16)
	sub.Size = UDim2.fromScale(1, 0.05)
	sub.ZIndex = 62
	local card = frame(ov, "Champ")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.6, 0.5)
	card.BackgroundColor3 = Theme.panel
	card.ZIndex = 62
	corner(card, 16)
	stroke(card, Theme.accent, 2, 0.15)
	local nm = text(card, champ.archetype, 34, Theme.accent)
	nm.Font = Theme.fontBlack
	nm.Position = UDim2.fromScale(0, 0.06)
	nm.Size = UDim2.fromScale(1, 0.14)
	nm.ZIndex = 63
	local stat = text(card, "TIER " .. champ.tier .. "   \u{2665} " .. champ.hp .. " HP", 16, Theme.text)
	stat.Position = UDim2.fromScale(0, 0.22)
	stat.Size = UDim2.fromScale(1, 0.07)
	stat.ZIndex = 63
	local abRow = frame(card, "Abilities")
	abRow.BackgroundTransparency = 1
	abRow.AnchorPoint = Vector2.new(0.5, 0.5)
	abRow.Position = UDim2.fromScale(0.5, 0.52)
	abRow.Size = UDim2.fromScale(0.9, 0.3)
	abRow.ZIndex = 63
	local al = Instance.new("UIListLayout")
	al.FillDirection = Enum.FillDirection.Horizontal
	al.HorizontalAlignment = Enum.HorizontalAlignment.Center
	al.VerticalAlignment = Enum.VerticalAlignment.Center
	al.Padding = UDim.new(0, 12)
	al.Parent = abRow
	for _, ab in champ.abilities do
		local slot = frame(abRow, "Ab")
		slot.Size = UDim2.fromScale(0.2, 1)
		slot.BackgroundColor3 = ab.color
		slot.ZIndex = 64
		corner(slot, 12)
		stroke(slot, Color3.new(1, 1, 1), 1.5, 0.5)
		local g = text(slot, ab.glyph, 26, Color3.fromRGB(10, 18, 28))
		g.Position = UDim2.fromScale(0, 0.06)
		g.Size = UDim2.fromScale(1, 0.5)
		g.ZIndex = 65
		local an = text(slot, ab.name, 12, Color3.fromRGB(10, 18, 28))
		an.Font = Theme.fontBlack
		an.Position = UDim2.fromScale(0, 0.56)
		an.Size = UDim2.fromScale(1, 0.2)
		an.ZIndex = 65
		local ap = text(slot, tostring(ab.power), 12, Color3.fromRGB(20, 30, 40))
		ap.Position = UDim2.fromScale(0, 0.76)
		ap.Size = UDim2.fromScale(1, 0.2)
		ap.ZIndex = 65
	end
	local duelBtn = Instance.new("TextButton")
	duelBtn.AnchorPoint = Vector2.new(0.5, 1)
	duelBtn.Position = UDim2.fromScale(0.5, 0.92)
	duelBtn.Size = UDim2.fromScale(0.5, 0.13)
	duelBtn.BackgroundColor3 = Theme.accent
	duelBtn.Text = "\u{2694} ENTER THE ARENA"
	duelBtn.Font = Theme.fontBlack
	duelBtn.TextSize = 20
	duelBtn.TextColor3 = Color3.fromRGB(10, 16, 26)
	duelBtn.ZIndex = 63
	corner(duelBtn, 10)
	duelBtn.Parent = card
	duelBtn.MouseButton1Click:Connect(function()
		ov:Destroy()
		if runDuel then runDuel(champ) end
	end)
	if DEBUG.autoPlay and runDuel then
		task.delay(1.5, function()
			ov:Destroy()
			runDuel(champ)
		end)
	end
end

-- ===== The Arena (active cooldown-brawl duel vs a real-player-style house Champion) =====
-- Element counter triangle so timing + build both matter (not just raw stats).
local COUNTER = { Kinetic = "Rapid", Rapid = "Cold", Cold = "Kinetic" } -- A beats B -> 1.4x
local function counterMult(atk: string, def: string): number
	return COUNTER[atk] == def and 1.4 or 1.0
end

-- House Champions: hand-authored fallback foes (stand in for real players' saved snapshots until
-- the DataStore ladder is added). Picked near your tier so the fight is fair-ish.
local HOUSE = {
	{ name = "Ashborn", archetype = "Bruiser", tag = "Kinetic", color = Color3.fromRGB(255, 150, 90),
		abilities = {
			{ name = "Cleave", glyph = "\u{2694}", color = Color3.fromRGB(255, 150, 90), tag = "Kinetic", power = 15, cd = 1.7 },
			{ name = "Stomp", glyph = "\u{25C9}", color = Color3.fromRGB(255, 190, 120), tag = "Kinetic", power = 9, cd = 1.0 },
		} },
	{ name = "Sleet", archetype = "Cryomancer", tag = "Cold", color = Color3.fromRGB(130, 220, 235),
		abilities = {
			{ name = "Glacier", glyph = "\u{2744}", color = Color3.fromRGB(130, 220, 235), tag = "Cold", power = 14, cd = 1.6 },
			{ name = "Sliver", glyph = "\u{2726}", color = Color3.fromRGB(180, 240, 250), tag = "Cold", power = 8, cd = 0.9 },
		} },
	{ name = "Quill", archetype = "Duelist", tag = "Rapid", color = Color3.fromRGB(180, 240, 120),
		abilities = {
			{ name = "Flurry", glyph = "\u{2726}", color = Color3.fromRGB(180, 240, 120), tag = "Rapid", power = 12, cd = 1.3 },
			{ name = "Jab", glyph = "\u{00BB}", color = Color3.fromRGB(210, 250, 160), tag = "Rapid", power = 7, cd = 0.7 },
		} },
}

local function restartGame()
	gui:Destroy()
	if hbConn then hbConn:Disconnect() end
	local clone = script:Clone()
	clone.Parent = script.Parent
	clone.Disabled = false
end

function runDuel(champ: any)
	-- pick a house opponent (avoid mirror archetype for variety), scale HP to your tier
	local pickList = {}
	for _, h in HOUSE do if h.archetype ~= champ.archetype then table.insert(pickList, h) end end
	if #pickList == 0 then pickList = HOUSE end
	local house = pickList[math.random(1, #pickList)]
	local opp = {
		name = house.name, archetype = house.archetype, tag = house.tag, color = house.color,
		hp = 80 + champ.tier * 7, maxHp = 80 + champ.tier * 7,
		abilities = {},
	}
	for _, a in house.abilities do
		local scaled = {}
		for k, v in a do scaled[k] = v end
		scaled.power = math.floor(a.power * (1 + champ.tier * 0.05))
		scaled.cd0 = a.cd
		scaled.cd = a.cd * 0.6 -- first cast comes a bit sooner
		scaled.wind = 0
		table.insert(opp.abilities, scaled)
	end
	local me = { hp = champ.hp, maxHp = champ.hp, guard = 0, guardCd = 0 }
	for _, a in champ.abilities do a.cd = 0 end

	-- ---- UI ----
	local ov = frame(bg, "Arena")
	ov.Size = UDim2.fromScale(1, 1)
	ov.BackgroundColor3 = Theme.bg
	ov.ZIndex = 70
	local title = text(ov, "\u{2694} THE ARENA", 26, Theme.gold)
	title.Font = Theme.fontBlack
	title.Position = UDim2.fromScale(0, 0.05)
	title.Size = UDim2.fromScale(1, 0.07)
	title.ZIndex = 71

	local function champPanel(anchorX: number, name: string, arche: string, color: Color3)
		local p = frame(ov, "Panel")
		p.AnchorPoint = Vector2.new(0.5, 0)
		p.Position = UDim2.fromScale(anchorX, 0.16)
		p.Size = UDim2.fromScale(0.34, 0.26)
		p.BackgroundColor3 = Theme.panel
		p.ZIndex = 71
		corner(p, 14)
		stroke(p, color, 2, 0.2)
		local av = frame(p, "Av")
		av.AnchorPoint = Vector2.new(0.5, 0)
		av.Position = UDim2.fromScale(0.5, 0.1)
		av.Size = UDim2.fromScale(0.4, 0.45)
		av.BackgroundColor3 = color
		av.ZIndex = 72
		corner(av, 12)
		local nm = text(p, name, 20, Theme.text)
		nm.Font = Theme.fontBlack
		nm.Position = UDim2.fromScale(0, 0.58)
		nm.Size = UDim2.fromScale(1, 0.14)
		nm.ZIndex = 72
		local ar = text(p, arche, 13, color)
		ar.Position = UDim2.fromScale(0, 0.72)
		ar.Size = UDim2.fromScale(1, 0.1)
		ar.ZIndex = 72
		local hpbg = frame(p, "HPbg")
		hpbg.AnchorPoint = Vector2.new(0.5, 1)
		hpbg.Position = UDim2.fromScale(0.5, 0.95)
		hpbg.Size = UDim2.fromScale(0.86, 0.09)
		hpbg.BackgroundColor3 = Color3.fromRGB(40, 44, 52)
		hpbg.ZIndex = 72
		corner(hpbg, 6)
		local hp = frame(hpbg, "HP")
		hp.Size = UDim2.fromScale(1, 1)
		hp.BackgroundColor3 = Theme.core
		hp.ZIndex = 73
		corner(hp, 6)
		return p, hp
	end
	local myPanel, myHpBar = champPanel(0.3, champ.name, champ.archetype, Theme.accent)
	local oppPanel, oppHpBar = champPanel(0.7, opp.name, opp.archetype, opp.color)
	local vs = text(ov, "VS", 30, Theme.textDim)
	vs.Font = Theme.fontBlack
	vs.AnchorPoint = Vector2.new(0.5, 0.5)
	vs.Position = UDim2.fromScale(0.5, 0.29)
	vs.Size = UDim2.fromScale(0.1, 0.1)
	vs.ZIndex = 72

	-- ability bar
	local bar = frame(ov, "Bar")
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(0.5, 0.92)
	bar.Size = UDim2.fromScale(0.8, 0.2)
	bar.ZIndex = 71
	local bl = Instance.new("UIListLayout")
	bl.FillDirection = Enum.FillDirection.Horizontal
	bl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bl.VerticalAlignment = Enum.VerticalAlignment.Center
	bl.Padding = UDim.new(0, 14)
	bl.Parent = bar

	local duelOver = false
	local function popDuel(s: string, x: number, color: Color3)
		local l = text(ov, s, 22, color)
		l.Font = Theme.fontBlack
		l.ZIndex = 80
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.Position = UDim2.fromScale(x, 0.42)
		l.Size = UDim2.fromScale(0.2, 0.08)
		TweenService:Create(l, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromScale(x, 0.34), TextTransparency = 1 }):Play()
		task.delay(0.65, function() l:Destroy() end)
	end
	local function hurt(target: string)
		local panel = target == "me" and myPanel or oppPanel
		local f = frame(panel, "Hit")
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = Theme.danger
		f.BackgroundTransparency = 0.4
		f.ZIndex = 78
		corner(f, 14)
		TweenService:Create(f, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		task.delay(0.22, function() f:Destroy() end)
	end

	local endDuel -- fwd
	local function fireMine(ab: any)
		if duelOver or ab.cd > 0 then return end
		ab.cd = ab.cd0 -- cd0 is set when the button is built, below
		local dmg = math.floor(ab.power * counterMult(ab.tag, opp.tag))
		opp.hp = math.max(0, opp.hp - dmg)
		oppHpBar.Size = UDim2.fromScale(opp.hp / opp.maxHp, 1)
		popDuel("-" .. dmg, 0.7, ab.color)
		hurt("opp")
		if ab.slow and ab.slow > 0 then
			for _, oa in opp.abilities do oa.cd += 0.5 end -- Frostbite slows their cooldowns
		end
		if opp.hp <= 0 then endDuel(true) end
	end

	-- ability buttons (with cooldown fill overlay)
	local myButtons = {}
	for _, ab in champ.abilities do
		ab.cd0 = ab.cd0 or (({ Slug = 1.5, Barrage = 1.0, Frostbite = 1.3 })[ab.name] or 1.3)
		ab.cd = 0
		local slot = frame(bar, "AbBtn")
		slot.Size = UDim2.fromScale(0.16, 1)
		slot.BackgroundColor3 = ab.color
		slot.ZIndex = 72
		corner(slot, 12)
		stroke(slot, Color3.new(1, 1, 1), 1.5, 0.5)
		local g = text(slot, ab.glyph, 26, Color3.fromRGB(10, 18, 28))
		g.Position = UDim2.fromScale(0, 0.08)
		g.Size = UDim2.fromScale(1, 0.5)
		g.ZIndex = 73
		local nm = text(slot, ab.name, 12, Color3.fromRGB(10, 18, 28))
		nm.Font = Theme.fontBlack
		nm.Position = UDim2.fromScale(0, 0.6)
		nm.Size = UDim2.fromScale(1, 0.2)
		nm.ZIndex = 73
		local cdFill = frame(slot, "CD")
		cdFill.AnchorPoint = Vector2.new(0.5, 1)
		cdFill.Position = UDim2.fromScale(0.5, 1)
		cdFill.Size = UDim2.fromScale(1, 0)
		cdFill.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		cdFill.BackgroundTransparency = 0.5
		cdFill.ZIndex = 74
		corner(cdFill, 12)
		button(slot).MouseButton1Click:Connect(function() fireMine(ab) end)
		table.insert(myButtons, { ab = ab, fill = cdFill })
	end
	-- Guard button
	local guardSlot = frame(bar, "Guard")
	guardSlot.Size = UDim2.fromScale(0.16, 1)
	guardSlot.BackgroundColor3 = Color3.fromRGB(90, 200, 160)
	guardSlot.ZIndex = 72
	corner(guardSlot, 12)
	stroke(guardSlot, Color3.new(1, 1, 1), 1.5, 0.5)
	local gg = text(guardSlot, "\u{1F6E1}", 24, Color3.fromRGB(10, 18, 28))
	gg.Position = UDim2.fromScale(0, 0.08)
	gg.Size = UDim2.fromScale(1, 0.5)
	gg.ZIndex = 73
	local gn = text(guardSlot, "GUARD", 12, Color3.fromRGB(10, 18, 28))
	gn.Font = Theme.fontBlack
	gn.Position = UDim2.fromScale(0, 0.6)
	gn.Size = UDim2.fromScale(1, 0.2)
	gn.ZIndex = 73
	local guardFill = frame(guardSlot, "CD")
	guardFill.AnchorPoint = Vector2.new(0.5, 1)
	guardFill.Position = UDim2.fromScale(0.5, 1)
	guardFill.Size = UDim2.fromScale(1, 0)
	guardFill.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	guardFill.BackgroundTransparency = 0.5
	guardFill.ZIndex = 74
	local function doGuard()
		if duelOver or me.guardCd > 0 then return end
		me.guard = 0.9
		me.guardCd = 3.0
		local ring = frame(myPanel, "Guarded")
		ring.Size = UDim2.fromScale(1, 1)
		ring.BackgroundTransparency = 1
		ring.ZIndex = 77
		stroke(ring, Color3.fromRGB(120, 240, 190), 3, 0)
		corner(ring, 14)
		task.delay(0.9, function() ring:Destroy() end)
	end
	button(guardSlot).MouseButton1Click:Connect(doGuard)

	-- opponent fires -> damages me (halved if guarding), with a wind-up "tell"
	local function oppFire(ab: any)
		local dmg = math.floor(ab.power * counterMult(ab.tag, champ.tag))
		if me.guard > 0 then dmg = math.floor(dmg * 0.4) end
		me.hp = math.max(0, me.hp - dmg)
		myHpBar.Size = UDim2.fromScale(me.hp / me.maxHp, 1)
		popDuel("-" .. dmg, 0.3, ab.color)
		hurt("me")
		if me.hp <= 0 then endDuel(false) end
	end

	-- ---- result ----
	function endDuel(won: boolean)
		if duelOver then return end
		duelOver = true
		local res = frame(ov, "Result")
		res.Size = UDim2.fromScale(1, 1)
		res.BackgroundColor3 = Theme.bg
		res.BackgroundTransparency = 0.15
		res.ZIndex = 85
		local big = text(res, won and "VICTORY" or "DEFEAT", 52, won and Theme.core or Theme.danger)
		big.Font = Theme.fontBlack
		big.AnchorPoint = Vector2.new(0.5, 0.5)
		big.Position = UDim2.fromScale(0.5, 0.4)
		big.Size = UDim2.fromScale(0.8, 0.2)
		big.ZIndex = 86
		big.TextTransparency = 1
		TweenService:Create(big, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
		local sub = text(res, won and ("You beat " .. opp.name .. " the " .. opp.archetype) or (opp.name .. " bested your " .. champ.archetype), 18, Theme.textDim)
		sub.Position = UDim2.fromScale(0, 0.54)
		sub.Size = UDim2.fromScale(1, 0.06)
		sub.ZIndex = 86
		local again = Instance.new("TextButton")
		again.AnchorPoint = Vector2.new(0.5, 0.5)
		again.Position = UDim2.fromScale(0.5, 0.68)
		again.Size = UDim2.fromScale(0.36, 0.1)
		again.BackgroundColor3 = Theme.accent
		again.Text = "NEW RUN"
		again.Font = Theme.fontBlack
		again.TextSize = 22
		again.TextColor3 = Color3.fromRGB(10, 16, 26)
		again.ZIndex = 86
		corner(again, 10)
		again.Parent = res
		again.MouseButton1Click:Connect(restartGame)
		if DEBUG.autoPlay then task.delay(2.5, restartGame) end
	end

	-- ---- duel loop (its own Heartbeat) ----
	local duelConn: RBXScriptConnection
	duelConn = RunService.Heartbeat:Connect(function(dt)
		if duelOver then
			duelConn:Disconnect()
			return
		end
		if me.guard > 0 then me.guard -= dt end
		if me.guardCd > 0 then me.guardCd -= dt end
		guardFill.Size = UDim2.fromScale(1, math.clamp(me.guardCd / 3.0, 0, 1))
		for _, mb in myButtons do
			if mb.ab.cd > 0 then mb.ab.cd -= dt end
			mb.fill.Size = UDim2.fromScale(1, math.clamp(mb.ab.cd / (mb.ab.cd0 or 1.2), 0, 1))
		end
		-- opponent AI: wind up then fire each ability on its cooldown
		for _, oa in opp.abilities do
			oa.cd -= dt
			if oa.cd <= 0 and oa.wind <= 0 then
				oa.wind = 0.5 -- tell
				local warn = frame(oppPanel, "Tell")
				warn.Size = UDim2.fromScale(1, 1)
				warn.BackgroundTransparency = 1
				warn.ZIndex = 76
				stroke(warn, oa.color, 3, 0)
				corner(warn, 14)
				task.delay(0.5, function() warn:Destroy() end)
			elseif oa.wind > 0 then
				oa.wind -= dt
				if oa.wind <= 0 then
					oppFire(oa)
					oa.cd = oa.cd0
				end
			end
		end
		-- DEBUG auto-pilot: fire ready abilities + guard on a tell
		if DEBUG.autoPlay then
			for _, mb in myButtons do
				if mb.ab.cd <= 0 then fireMine(mb.ab) end
			end
			if me.guardCd <= 0 and oppPanel:FindFirstChild("Tell") then doGuard() end
		end
	end)
end

-- ===== Title / start menu (only on first entry of a session; NEW RUN skips it) =====
if not state.started then
	local menu = frame(bg, "Menu")
	menu.Size = UDim2.fromScale(1, 1)
	menu.BackgroundColor3 = Theme.bg
	menu.ZIndex = 95
	do
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Color = ColorSequence.new(Color3.fromRGB(18, 22, 30), Color3.fromRGB(12, 13, 17))
		g.Parent = menu
	end
	local t1 = text(menu, "GAUNTLET", 60, Theme.accent)
	t1.Font = Theme.fontBlack
	t1.AnchorPoint = Vector2.new(0.5, 1)
	t1.Position = UDim2.fromScale(0.5, 0.4)
	t1.Size = UDim2.fromScale(0.9, 0.13)
	t1.ZIndex = 96
	local t2 = text(menu, "& GLORY", 60, Theme.gold)
	t2.Font = Theme.fontBlack
	t2.AnchorPoint = Vector2.new(0.5, 0)
	t2.Position = UDim2.fromScale(0.5, 0.4)
	t2.Size = UDim2.fromScale(0.9, 0.13)
	t2.ZIndex = 96
	local tag = text(menu, "survive the gauntlet  \u{2022}  forge a champion  \u{2022}  duel the ladder", 17, Theme.textDim)
	tag.Position = UDim2.fromScale(0, 0.56)
	tag.Size = UDim2.fromScale(1, 0.05)
	tag.ZIndex = 96
	local play = Instance.new("TextButton")
	play.AnchorPoint = Vector2.new(0.5, 0.5)
	play.Position = UDim2.fromScale(0.5, 0.7)
	play.Size = UDim2.fromScale(0.3, 0.1)
	play.BackgroundColor3 = Theme.accent
	play.Text = "PLAY"
	play.Font = Theme.fontBlack
	play.TextSize = 26
	play.TextColor3 = Color3.fromRGB(10, 16, 26)
	play.ZIndex = 96
	corner(play, 12)
	play.Parent = menu
	local function beginGame()
		(_G :: any).GGStarted = true
		state.started = true
		TweenService:Create(menu, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
		for _, c in menu:GetChildren() do
			if c:IsA("TextLabel") or c:IsA("TextButton") then
				TweenService:Create(c, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			end
		end
		task.delay(0.32, function() menu:Destroy() end)
	end
	play.MouseButton1Click:Connect(beginGame)
	if DEBUG.autoPlay then
		task.delay(0.4, beginGame)
	end
end

print("[G&G] full loop ready")
