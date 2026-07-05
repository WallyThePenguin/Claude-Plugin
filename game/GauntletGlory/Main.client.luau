--!strict
-- GAUNTLET & GLORY — MVP foundation (first playable slice).
-- A GUI-only, one-life, infinite roguelite tower-defense down a single vertical lane.
-- This one LocalScript builds the whole UI in code and runs the game loop client-side
-- (no meshes, no parts, no DataStore). Modularized into ForgeChampion/DuelEngine/etc. as it grows.
--
-- THIS SLICE proves the hardest technical bet (GUI-Frame TD on a Heartbeat loop is stable + fun):
-- lane render, pooled enemies tweening down via ONE Heartbeat loop with a live-enemy cap + queue,
-- a basic auto-firing tower placeable on slots (instant hitscan-flash), coins, formula wave scaling,
-- and the ONE-LIFE fail (a single leak ends the run -> shake/flash -> run summary -> retry).

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ===== Theme (single source of palette/juice) =====
local Theme = {
	bg = Color3.fromRGB(14, 16, 20),
	panel = Color3.fromRGB(22, 26, 33),
	panelHi = Color3.fromRGB(32, 38, 48),
	lane = Color3.fromRGB(18, 21, 27),
	accent = Color3.fromRGB(94, 160, 255), -- brand blue
	gold = Color3.fromRGB(255, 205, 90),
	danger = Color3.fromRGB(255, 84, 96),
	core = Color3.fromRGB(120, 235, 190),
	text = Color3.fromRGB(232, 238, 246),
	textDim = Color3.fromRGB(140, 150, 165),
	enemy = Color3.fromRGB(226, 96, 110),
	elite = Color3.fromRGB(196, 120, 255),
	tower = Color3.fromRGB(120, 200, 255),
	font = Enum.Font.GothamBold,
	fontBlack = Enum.Font.GothamBlack,
}

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
	return c
end
local function stroke(parent: Instance, color: Color3, th: number, tr: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = th
	s.Transparency = tr or 0
	s.Parent = parent
	return s
end
local function newFrame(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Theme.panel
	f.Parent = parent
	return f
end
local function newText(parent: Instance, text: string, size: number, color: Color3?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Theme.font
	t.Text = text
	t.TextScaled = false
	t.TextSize = size
	t.TextColor3 = color or Theme.text
	t.Parent = parent
	return t
end

-- ===== Root ScreenGui =====
local gui = Instance.new("ScreenGui")
gui.Name = "GauntletGlory"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 50
gui.Parent = playerGui

local bg = newFrame(gui, "BG")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Theme.bg

-- Lane column, centered, tall. Scale-based so it fits any screen (mobile-friendly).
local LANE_W = 0.30
local lane = newFrame(bg, "Lane")
lane.AnchorPoint = Vector2.new(0.5, 0.5)
lane.Position = UDim2.fromScale(0.5, 0.5)
lane.Size = UDim2.fromScale(LANE_W, 0.88)
lane.BackgroundColor3 = Theme.lane
corner(lane, 14)
stroke(lane, Theme.panelHi, 2, 0.2)
do
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(Color3.fromRGB(24, 28, 36), Color3.fromRGB(15, 17, 22))
	g.Parent = lane
end

-- Core bar at the bottom of the lane (1 HP — the life).
local core = newFrame(lane, "Core")
core.AnchorPoint = Vector2.new(0.5, 1)
core.Position = UDim2.fromScale(0.5, 1)
core.Size = UDim2.new(1, -8, 0, 14)
core.BackgroundColor3 = Theme.core
corner(core, 7)
local coreGlow = stroke(core, Theme.core, 3, 0.3)

-- 8 tower slots (4 per side), evenly spaced down the lane.
type Slot = { frame: Frame, side: number, y: number, tower: any }
local slots: { Slot } = {}
local SLOT_COUNT_PER_SIDE = 4
for side = 0, 1 do
	for i = 0, SLOT_COUNT_PER_SIDE - 1 do
		local yScale = 0.12 + (i / (SLOT_COUNT_PER_SIDE - 1)) * 0.66
		local slot = newFrame(lane, "Slot")
		slot.AnchorPoint = Vector2.new(0.5, 0.5)
		slot.Size = UDim2.fromScale(0.26, 0.10)
		slot.Position = UDim2.fromScale(side == 0 and -0.02 or 1.02, yScale)
		slot.BackgroundColor3 = Theme.panel
		slot.BackgroundTransparency = 0.15
		corner(slot, 10)
		stroke(slot, Theme.panelHi, 2, 0.3)
		local plus = newText(slot, "+", 22, Theme.textDim)
		plus.Size = UDim2.fromScale(1, 1)
		local btn = Instance.new("TextButton")
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.Size = UDim2.fromScale(1, 1)
		btn.Parent = slot
		table.insert(slots, { frame = slot, side = side, y = yScale, tower = nil, _plus = plus, _btn = btn } :: any)
	end
end

-- ===== HUD =====
local hud = newFrame(bg, "HUD")
hud.BackgroundTransparency = 1
hud.Size = UDim2.new(1, 0, 0, 60)
hud.Position = UDim2.fromScale(0, 0)

local waveLabel = newText(hud, "WAVE 1", 24, Theme.text)
waveLabel.Font = Theme.fontBlack
waveLabel.AnchorPoint = Vector2.new(0.5, 0)
waveLabel.Position = UDim2.fromScale(0.5, 0.25)
waveLabel.Size = UDim2.fromScale(0.5, 0.6)

local coinLabel = newText(hud, "0", 22, Theme.gold)
coinLabel.AnchorPoint = Vector2.new(1, 0)
coinLabel.Position = UDim2.new(1, -20, 0, 15)
coinLabel.Size = UDim2.fromScale(0.25, 0.5)
coinLabel.TextXAlignment = Enum.TextXAlignment.Right

-- Big centered wave banner (juice).
local banner = newText(bg, "", 46, Theme.accent)
banner.Font = Theme.fontBlack
banner.AnchorPoint = Vector2.new(0.5, 0.5)
banner.Position = UDim2.fromScale(0.5, 0.35)
banner.Size = UDim2.fromScale(0.8, 0.12)
banner.TextTransparency = 1

-- ===== State =====
local state = {
	wave = 0,
	coins = 30,
	alive = true,
	enemies = {} :: { any },
	spawnQueue = {} :: { any },
	towers = {} :: { any },
}
local MAX_LIVE_ENEMIES = 40
local TOWER_COST = 15

local function setCoins(n: number)
	state.coins = n
	coinLabel.Text = "\u{1FA99} " .. tostring(n)
end
setCoins(state.coins)

-- ===== FeedbackFX (juice primitives) =====
local function popup(text: string, atScale: Vector2, color: Color3)
	local l = newText(lane, text, 18, color)
	l.Font = Theme.fontBlack
	l.ZIndex = 20
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(atScale.X, atScale.Y)
	l.Size = UDim2.fromScale(0.4, 0.06)
	TweenService:Create(l, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(atScale.X, atScale.Y - 0.06),
		TextTransparency = 1,
	}):Play()
	task.delay(0.6, function()
		l:Destroy()
	end)
end

local function flashBanner(text: string, color: Color3)
	banner.Text = text
	banner.TextColor3 = color
	banner.TextTransparency = 0
	banner.Size = UDim2.fromScale(0.5, 0.10)
	TweenService:Create(banner, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(0.8, 0.12),
	}):Play()
	task.delay(0.9, function()
		TweenService:Create(banner, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
	end)
end

-- ===== Enemy pool =====
local function makeEnemy(): any
	local f = newFrame(lane, "Enemy")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromScale(0.34, 0.055)
	f.BackgroundColor3 = Theme.enemy
	f.Visible = false
	f.ZIndex = 8
	corner(f, 10)
	stroke(f, Color3.new(1, 1, 1), 1.5, 0.6)
	local bar = newFrame(f, "HP")
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 3, 1, -2)
	bar.Size = UDim2.new(1, -6, 0, 3)
	bar.BackgroundColor3 = Color3.fromRGB(120, 255, 150)
	bar.ZIndex = 9
	corner(bar, 2)
	return { frame = f, hp = 0, maxHp = 0, speed = 0, progress = 0, active = false, hpbar = bar, elite = false }
end
local enemyPool: { any } = {}
for _ = 1, MAX_LIVE_ENEMIES do
	table.insert(enemyPool, makeEnemy())
end
local function acquireEnemy(): any?
	for _, e in enemyPool do
		if not e.active then
			return e
		end
	end
	return nil
end

-- ===== Wave director (pure-ish formula) =====
local function waveSchedule(n: number): { any }
	local count = 6 + math.floor(n * 1.6)
	local hp = math.floor(12 * (1.16 ^ n))
	local speed = 0.05 + math.min(n, 30) * 0.0015 -- progress per second
	local elite = (n % 5 == 0)
	local list = {}
	for _ = 1, count do
		table.insert(list, {
			hp = elite and hp * 6 or hp,
			speed = elite and speed * 0.6 or speed,
			elite = elite,
		})
	end
	return list
end

local function spawnEnemy(def: any)
	local e = acquireEnemy()
	if not e then
		return -- pool exhausted; queue keeps it for next frame (cap respected)
	end
	e.hp = def.hp
	e.maxHp = def.hp
	e.speed = def.speed
	e.elite = def.elite
	e.progress = 0
	e.active = true
	e.frame.BackgroundColor3 = def.elite and Theme.elite or Theme.enemy
	e.frame.Size = def.elite and UDim2.fromScale(0.5, 0.075) or UDim2.fromScale(0.34, 0.055)
	e.frame.Position = UDim2.fromScale(0.5, 0.05)
	e.hpbar.Size = UDim2.new(1, -6, 0, 3)
	e.frame.Visible = true
	table.insert(state.enemies, e)
end

local function releaseEnemy(e: any)
	e.active = false
	e.frame.Visible = false
	local idx = table.find(state.enemies, e)
	if idx then
		table.remove(state.enemies, idx)
	end
end

-- ===== One-life fail =====
local endRun -- fwd
-- ===== Towers =====
local function placeTower(slot: any)
	if slot.tower or not state.alive then
		return
	end
	if state.coins < TOWER_COST then
		popup("need \u{1FA99}", Vector2.new(slot.side == 0 and 0.1 or 0.9, slot.y), Theme.danger)
		return
	end
	setCoins(state.coins - TOWER_COST)
	slot._plus.Visible = false
	local t = newFrame(slot.frame, "Tower")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = Theme.tower
	t.BackgroundTransparency = 0.05
	corner(t, 10)
	stroke(t, Color3.new(1, 1, 1), 1.5, 0.4)
	local glyph = newText(t, "\u{25C9}", 22, Color3.fromRGB(10, 20, 30))
	glyph.Size = UDim2.fromScale(1, 1)
	slot.tower = {
		slot = slot,
		range = 0.22, -- vertical range band (progress units) around the slot's y
		fireRate = 0.7,
		damage = 9,
		cd = 0,
		frame = t,
	}
	table.insert(state.towers, slot.tower)
	-- place pop
	t.Size = UDim2.fromScale(0.4, 0.4)
	TweenService:Create(t, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) }):Play()
end

for _, slot in slots do
	slot._btn.MouseButton1Click:Connect(function()
		placeTower(slot)
	end)
end

local function fireBolt(fromY: number, side: number, toY: number)
	-- instant hitscan flash: a thin bright frame from the tower's edge to the enemy
	local bolt = newFrame(lane, "Bolt")
	bolt.BackgroundColor3 = Theme.tower
	bolt.ZIndex = 15
	bolt.AnchorPoint = Vector2.new(0.5, 0.5)
	bolt.BackgroundTransparency = 0.1
	corner(bolt, 2)
	local x0 = side == 0 and 0.08 or 0.92
	local midY = (fromY + toY) / 2
	local dy = (toY - fromY)
	local dx = 0.5 - x0
	local len = math.sqrt(dx * dx + dy * dy)
	bolt.Size = UDim2.fromScale(len, 0.008)
	bolt.Position = UDim2.fromScale((x0 + 0.5) / 2, midY)
	bolt.Rotation = math.deg(math.atan2(dy, dx))
	TweenService:Create(bolt, TweenInfo.new(0.12), { BackgroundTransparency = 1 }):Play()
	task.delay(0.13, function()
		bolt:Destroy()
	end)
end

local function damageEnemy(e: any, dmg: number, side: number, atY: number)
	e.hp -= dmg
	e.hpbar.Size = UDim2.new(math.clamp(e.hp / e.maxHp, 0, 1), -6, 0, 3)
	if e.hp <= 0 then
		local reward = e.elite and 30 or 4
		setCoins(state.coins + reward)
		popup("+" .. reward, Vector2.new(0.5, atY), Theme.gold)
		-- death pop
		local f = e.frame
		TweenService:Create(f, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Size = UDim2.fromScale(0.02, 0.02) }):Play()
		task.delay(0.18, function()
			releaseEnemy(e)
		end)
		e.active = false -- stop targeting immediately (frame recycles after the pop)
	end
end

-- ===== Main Heartbeat loop (ONE connection drives everything) =====
local hbConn: RBXScriptConnection
hbConn = RunService.Heartbeat:Connect(function(dt)
	if not state.alive then
		return
	end
	-- drain spawn queue into the pool (respecting the live cap)
	if #state.spawnQueue > 0 and #state.enemies < MAX_LIVE_ENEMIES then
		local def = state.spawnQueue[1]
		def._t = (def._t or 0) + dt
		if def._t >= (def._gap or 0) then
			table.remove(state.spawnQueue, 1)
			spawnEnemy(def)
		end
	end
	-- move enemies down; detect leak (one-life fail)
	for i = #state.enemies, 1, -1 do
		local e = state.enemies[i]
		if e.active then
			e.progress += e.speed * dt
			if e.progress >= 0.92 then
				endRun()
				return
			end
			e.frame.Position = UDim2.fromScale(0.5, 0.05 + e.progress * 0.87)
		end
	end
	-- towers acquire + fire
	for _, tw in state.towers do
		tw.cd -= dt
		if tw.cd <= 0 then
			-- nearest-to-core enemy within the tower's vertical band
			local best, bestProg = nil, -1
			for _, e in state.enemies do
				if e.active then
					local ey = 0.05 + e.progress * 0.87
					if math.abs(ey - tw.slot.y) <= tw.range and e.progress > bestProg then
						best, bestProg = e, e.progress
					end
				end
			end
			if best then
				local ey = 0.05 + best.progress * 0.87
				fireBolt(tw.slot.y, tw.slot.side, ey)
				damageEnemy(best, tw.damage, tw.slot.side, ey)
				tw.cd = tw.fireRate
			end
		end
	end
end)

-- ===== Wave flow =====
local function startWave()
	state.wave += 1
	waveLabel.Text = "WAVE " .. state.wave
	flashBanner(state.wave % 5 == 0 and "ELITE WAVE" or ("WAVE " .. state.wave), state.wave % 5 == 0 and Theme.elite or Theme.accent)
	local sched = waveSchedule(state.wave)
	local gap = math.max(0.35, 0.9 - state.wave * 0.02)
	for _, def in sched do
		def._gap = gap
		table.insert(state.spawnQueue, def)
	end
end

local function waveClear(): boolean
	return #state.spawnQueue == 0 and #state.enemies == 0
end

-- watcher: when a wave is cleared, brief intermission then next wave (draft slots in here later)
task.spawn(function()
	startWave()
	while state.alive do
		task.wait(0.5)
		if state.alive and waveClear() then
			task.wait(1.2) -- intermission (draft will live here)
			if state.alive then
				startWave()
			end
		end
	end
end)

-- ===== One-life fail =====
function endRun()
	if not state.alive then
		return
	end
	state.alive = false
	-- red flash + shake
	local flash = newFrame(bg, "Flash")
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Theme.danger
	flash.BackgroundTransparency = 0.35
	flash.ZIndex = 30
	TweenService:Create(flash, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
	for _ = 1, 6 do
		bg.Position = UDim2.fromOffset(math.random(-8, 8), math.random(-8, 8))
		task.wait(0.03)
	end
	bg.Position = UDim2.fromScale(0, 0)
	-- run summary
	local over = newFrame(bg, "Summary")
	over.Size = UDim2.fromScale(1, 1)
	over.BackgroundColor3 = Theme.bg
	over.BackgroundTransparency = 0.15
	over.ZIndex = 31
	local card = newFrame(over, "Card")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.6, 0.4)
	card.BackgroundColor3 = Theme.panel
	card.ZIndex = 32
	corner(card, 16)
	stroke(card, Theme.accent, 2, 0.2)
	local dead = newText(card, "RUN OVER", 30, Theme.danger)
	dead.Font = Theme.fontBlack
	dead.Position = UDim2.fromScale(0, 0.12)
	dead.Size = UDim2.fromScale(1, 0.2)
	dead.ZIndex = 33
	local reached = newText(card, "You reached Wave " .. state.wave, 22, Theme.text)
	reached.Position = UDim2.fromScale(0, 0.4)
	reached.Size = UDim2.fromScale(1, 0.15)
	reached.ZIndex = 33
	local forgeNote = newText(card, "(next: this run forges your Champion \u{2192} duel)", 14, Theme.textDim)
	forgeNote.Position = UDim2.fromScale(0, 0.56)
	forgeNote.Size = UDim2.fromScale(1, 0.12)
	forgeNote.ZIndex = 33
	local retry = Instance.new("TextButton")
	retry.AnchorPoint = Vector2.new(0.5, 1)
	retry.Position = UDim2.fromScale(0.5, 0.88)
	retry.Size = UDim2.fromScale(0.5, 0.2)
	retry.BackgroundColor3 = Theme.accent
	retry.Text = "RETRY"
	retry.Font = Theme.fontBlack
	retry.TextSize = 22
	retry.TextColor3 = Color3.fromRGB(10, 16, 26)
	retry.ZIndex = 33
	corner(retry, 10)
	retry.Parent = card
	retry.MouseButton1Click:Connect(function()
		gui:Destroy()
		if hbConn then
			hbConn:Disconnect()
		end
		-- rebuild by re-running: reset via a fresh require is overkill here; just reload the script
		local clone = script:Clone()
		clone.Parent = playerGui
		clone.Disabled = false
	end)
end

print("[G&G] foundation running")
