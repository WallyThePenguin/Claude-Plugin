-- WaveHud controller: renders the server''s round state (Workspace attributes set by RoundLoop):
--   CurrentWave (number) - EnemiesRemaining (number) - RoundState (intermission|wave|victory)
local Workspace = game:GetService("Workspace")
local gui = script.Parent
local wave = gui.Banner.WaveLabel
local sub = gui.Banner.SubLabel
local splash = gui.Splash

local function render()
	local state = tostring(Workspace:GetAttribute("RoundState") or "intermission")
	local waveN = tonumber(Workspace:GetAttribute("CurrentWave")) or 0
	local left = tonumber(Workspace:GetAttribute("EnemiesRemaining")) or 0
	if state == "victory" then
		wave.Text = "ALL WAVES CLEARED"
		sub.Text = "the arena is quiet again"
		splash.Text = "VICTORY"
		splash.Visible = true
	elseif state == "wave" then
		wave.Text = string.format("WAVE %d", waveN)
		sub.Text = string.format("%d Husk%s remaining", left, left == 1 and "" or "s")
		splash.Visible = false
	else
		wave.Text = waveN == 0 and "GET READY" or string.format("WAVE %d INCOMING", waveN + 1)
		sub.Text = "the Husks are coming"
		splash.Visible = false
	end
end

for _, attr in { "RoundState", "CurrentWave", "EnemiesRemaining" } do
	Workspace:GetAttributeChangedSignal(attr):Connect(render)
end
render()