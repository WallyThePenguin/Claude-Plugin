--!strict
-- Widget (M9): the chat panel. A scrolling transcript + message input, a session-history view you
-- can reopen, New chat, and a compact proxy-key row. Chats persist via Sessions (survive restarts).
-- A DockWidgetPluginGui renders a Frame-rooted tree (NOT a ScreenGui). Manual anchored layout so the
-- transcript flexes between a fixed header and a bottom input row.

local Widget = {}

export type Deps = {
	config: any,
	anthropic: any,
	agentLoop: any,
	systemPrompt: string,
	conversation: any,
	sessions: any,
	taskList: any,
	memory: any,
	skills: any,
}

local TEXT = Color3.fromRGB(225, 225, 228)
local MUTED = Color3.fromRGB(150, 150, 155)
local YOU = Color3.fromRGB(120, 170, 255)
local ERR = Color3.fromRGB(255, 120, 120)
local DONE = Color3.fromRGB(120, 190, 130)
local BTN_BG = Color3.fromRGB(56, 56, 62)

local function button(text: string): TextButton
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = BTN_BG
	b.BorderSizePixel = 0
	b.TextColor3 = TEXT
	b.TextSize = 14
	b.Font = Enum.Font.Gotham
	b.Text = text
	b.AutoButtonColor = true
	return b
end

function Widget.mount(gui: Instance, deps: Deps)
	local root = Instance.new("Frame")
	root.Name = "StudioAgentRoot"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = root

	-- Proxy key row (top).
	local keyBox = Instance.new("TextBox")
	keyBox.Size = UDim2.new(1, -58, 0, 26)
	keyBox.Position = UDim2.fromOffset(0, 0)
	keyBox.BackgroundColor3 = Color3.fromRGB(40, 40, 44)
	keyBox.BorderSizePixel = 0
	keyBox.TextColor3 = TEXT
	keyBox.PlaceholderText = "proxy key (Bearer)"
	keyBox.PlaceholderColor3 = MUTED
	keyBox.Text = deps.config:getProxyKey()
	keyBox.ClearTextOnFocus = false
	keyBox.TextSize = 13
	keyBox.Font = Enum.Font.Code
	keyBox.TextXAlignment = Enum.TextXAlignment.Left
	keyBox.Parent = root
	local saveBtn = button("Save")
	saveBtn.Size = UDim2.fromOffset(54, 26)
	saveBtn.Position = UDim2.new(1, -54, 0, 0)
	saveBtn.Parent = root

	-- Control row (compact so all four buttons fit the 260px min dock width).
	local newBtn = button("New chat")
	newBtn.Size = UDim2.fromOffset(64, 26)
	newBtn.Position = UDim2.fromOffset(0, 32)
	newBtn.Parent = root
	local histBtn = button("History")
	histBtn.Size = UDim2.fromOffset(56, 26)
	histBtn.Position = UDim2.fromOffset(68, 32)
	histBtn.Parent = root
	local memBtn = button("Memory")
	memBtn.Size = UDim2.fromOffset(56, 26)
	memBtn.Position = UDim2.fromOffset(128, 32)
	memBtn.Parent = root
	local skillsBtn = button("Skills")
	skillsBtn.Size = UDim2.fromOffset(52, 26)
	skillsBtn.Position = UDim2.fromOffset(188, 32)
	skillsBtn.Parent = root
	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -244, 0, 26)
	status.Position = UDim2.fromOffset(244, 32)
	status.TextColor3 = MUTED
	status.TextSize = 12
	status.Font = Enum.Font.Gotham
	status.TextXAlignment = Enum.TextXAlignment.Right
	status.TextTruncate = Enum.TextTruncate.AtEnd
	status.Text = ""
	status.Parent = root

	-- Main area (flexes between the header rows ending at y=96 and the input row at the bottom).
	local TOP = 64 -- two 26px header rows on a 32px stride: proxy-key (y0), control (y32).
	local INPUT_H = 70
	-- Checklist (update_tasks) layout constants. The checklist is pinned at y=TOP and the transcript
	-- reflows below it; height is derived from task count + collapsed state (no AutomaticSize race).
	local HEADER_H = 24
	local ROW_H = 20
	local MAX_BODY = 140
	local GAP = 4
	local MIN_TRANSCRIPT = 72 -- keep at least this much transcript visible even with a big checklist
	local function scroller(): ScrollingFrame
		local sf = Instance.new("ScrollingFrame")
		sf.Size = UDim2.new(1, 0, 1, -(TOP + INPUT_H + 4))
		sf.Position = UDim2.fromOffset(0, TOP)
		sf.BackgroundColor3 = Color3.fromRGB(30, 30, 33)
		sf.BorderSizePixel = 0
		sf.ScrollBarThickness = 6
		sf.CanvasSize = UDim2.new()
		sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
		sf.Parent = root
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = sf
		local p = Instance.new("UIPadding")
		p.PaddingTop = UDim.new(0, 6)
		p.PaddingLeft = UDim.new(0, 6)
		p.PaddingRight = UDim.new(0, 6)
		p.Parent = sf
		return sf
	end

	local transcript = scroller()
	local sessionList = scroller()
	sessionList.Visible = false
	local memoryList = scroller()
	memoryList.Visible = false
	local skillsList = scroller()
	skillsList.Visible = false

	-- Checklist container (between the control row and the transcript). Hidden when empty or while the
	-- sessions/history view is shown. Manual height; the transcript's geometry follows via layoutChecklist().
	local checklist = Instance.new("Frame")
	checklist.Name = "Checklist"
	checklist.BackgroundTransparency = 1
	checklist.Position = UDim2.fromOffset(0, TOP)
	checklist.Size = UDim2.fromScale(1, 0) -- placeholder; layoutChecklist() sets the real height
	checklist.Visible = false
	checklist.Parent = root

	local checklistHeader = button("Tasks")
	checklistHeader.BackgroundColor3 = Color3.fromRGB(44, 44, 48)
	checklistHeader.Size = UDim2.new(1, 0, 0, HEADER_H)
	checklistHeader.Position = UDim2.fromOffset(0, 0)
	checklistHeader.TextXAlignment = Enum.TextXAlignment.Left
	checklistHeader.TextSize = 13
	checklistHeader.Parent = checklist
	local headerPad = Instance.new("UIPadding")
	headerPad.PaddingLeft = UDim.new(0, 6)
	headerPad.Parent = checklistHeader

	local checklistBody = Instance.new("ScrollingFrame")
	checklistBody.Name = "ChecklistBody"
	checklistBody.BackgroundTransparency = 1
	checklistBody.BorderSizePixel = 0
	checklistBody.Position = UDim2.fromOffset(0, HEADER_H)
	checklistBody.Size = UDim2.fromScale(1, 0) -- placeholder; layoutChecklist() sets the real height
	checklistBody.ScrollBarThickness = 4
	checklistBody.CanvasSize = UDim2.new()
	checklistBody.AutomaticCanvasSize = Enum.AutomaticSize.Y
	checklistBody.Parent = checklist
	local bodyList = Instance.new("UIListLayout")
	bodyList.Padding = UDim.new(0, 0)
	bodyList.SortOrder = Enum.SortOrder.LayoutOrder
	bodyList.Parent = checklistBody
	local bodyPad = Instance.new("UIPadding")
	bodyPad.PaddingLeft = UDim.new(0, 6)
	bodyPad.Parent = checklistBody

	-- Checklist state + rendering ----------------------------------------------------------------
	local currentTasks: { any } = {}
	local checklistCollapsed = false

	local function rebuildChecklistRows()
		for _, child in checklistBody:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		for i, t in ipairs(currentTasks) do
			local glyph, color
			if t.status == "completed" then
				glyph, color = "●", DONE
			elseif t.status == "in_progress" then
				glyph, color = "◐", YOU
			else
				glyph, color = "○", MUTED
			end
			local row = Instance.new("TextLabel")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, -8, 0, ROW_H)
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.TextYAlignment = Enum.TextYAlignment.Center
			row.TextTruncate = Enum.TextTruncate.AtEnd
			row.TextColor3 = color
			row.TextSize = 13
			row.Font = Enum.Font.Gotham
			row.Text = glyph .. "  " .. tostring(t.content)
			row.LayoutOrder = i
			row.Parent = checklistBody
		end
	end

	-- Size the checklist from task count + collapsed state and reflow the transcript below it. Hidden
	-- when empty or while the sessions view is shown. Called on every event that can change its height.
	local function layoutChecklist()
		local n = #currentTasks
		local show = n > 0 and not sessionList.Visible and not memoryList.Visible
		checklist.Visible = show

		local done = 0
		for _, t in ipairs(currentTasks) do
			if t.status == "completed" then
				done += 1
			end
		end
		local chevron = if checklistCollapsed then "▸ " else "▾ "
		checklistHeader.Text = chevron .. "Tasks  " .. tostring(done) .. "/" .. tostring(n)

		local bodyH = if checklistCollapsed then 0 else math.min(n * ROW_H, MAX_BODY)
		-- Clamp the body so the transcript keeps a minimum visible band on a small dock (the body
		-- scrolls). root.AbsoluteSize is 0 before the first layout pass; skip the clamp until known.
		local contentH = root.AbsoluteSize.Y - 16 -- minus UIPadding (8 top + 8 bottom)
		if show and not checklistCollapsed and contentH > 0 then
			local maxBodyH = contentH - (TOP + HEADER_H + GAP + INPUT_H + 4 + MIN_TRANSCRIPT)
			bodyH = math.clamp(bodyH, 0, math.max(0, maxBodyH))
		end
		checklistBody.Visible = show and not checklistCollapsed
		checklistBody.Size = UDim2.new(1, 0, 0, bodyH)

		local h = if show then HEADER_H + bodyH else 0
		checklist.Size = UDim2.new(1, 0, 0, h)

		local top = TOP + (if h > 0 then h + GAP else 0)
		transcript.Position = UDim2.fromOffset(0, top)
		transcript.Size = UDim2.new(1, 0, 1, -(top + INPUT_H + 4))
	end

	local function renderChecklist(tasks: { any })
		currentTasks = tasks or {}
		rebuildChecklistRows()
		layoutChecklist()
	end

	checklistHeader.Activated:Connect(function()
		checklistCollapsed = not checklistCollapsed
		layoutChecklist()
	end)

	-- Reflow when the dock panel is resized so the transcript/checklist split stays sane at any height.
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutChecklist)

	-- Input row (bottom).
	local taskBox = Instance.new("TextBox")
	taskBox.Size = UDim2.new(1, 0, 0, 40)
	taskBox.Position = UDim2.new(0, 0, 1, -INPUT_H)
	taskBox.BackgroundColor3 = Color3.fromRGB(40, 40, 44)
	taskBox.BorderSizePixel = 0
	taskBox.TextColor3 = TEXT
	taskBox.PlaceholderText = "Ask Claude to build something (the chat remembers)"
	taskBox.PlaceholderColor3 = MUTED
	taskBox.ClearTextOnFocus = false
	taskBox.MultiLine = true
	taskBox.TextSize = 14
	taskBox.Font = Enum.Font.Gotham
	taskBox.TextXAlignment = Enum.TextXAlignment.Left
	taskBox.TextYAlignment = Enum.TextYAlignment.Top
	taskBox.Parent = root
	local sendBtn = button("Send")
	sendBtn.Size = UDim2.new(0.5, -3, 0, 24)
	sendBtn.Position = UDim2.new(0, 0, 1, -26)
	sendBtn.Parent = root
	local stopBtn = button("Stop")
	stopBtn.Size = UDim2.new(0.5, -3, 0, 24)
	stopBtn.Position = UDim2.new(0.5, 3, 1, -26)
	stopBtn.Parent = root

	-- Transcript rendering ----------------------------------------------------------------------
	local rowOrder = 0
	local function clearScroller(sf: ScrollingFrame)
		for _, child in sf:GetChildren() do
			-- Destroy any visual child (TextLabel / TextButton / Frame rows); UIListLayout / UIPadding
			-- are not GuiObjects, so they survive.
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
	local function addRow(color: Color3, text: string)
		rowOrder += 1
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -8, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextColor3 = color
		label.TextSize = 14
		label.Font = Enum.Font.Gotham
		label.Text = text
		label.LayoutOrder = rowOrder
		label.Parent = transcript
		transcript.CanvasPosition = Vector2.new(0, 1e6) -- clamp-to-bottom
	end

	local function rebuildTranscript()
		clearScroller(transcript)
		rowOrder = 0
		for _, msg in deps.conversation.messages do
			if msg.role == "user" and type(msg.content) == "string" then
				addRow(YOU, "You: " .. msg.content)
			elseif msg.role == "assistant" and type(msg.content) == "table" then
				for _, block in msg.content do
					if type(block) == "table" then
						if block.type == "text" and type(block.text) == "string" then
							addRow(TEXT, "Claude: " .. block.text)
						elseif block.type == "tool_use" then
							addRow(MUTED, "[used " .. tostring(block.name) .. "]")
						end
					end
				end
			end
		end
	end

	-- Sessions -----------------------------------------------------------------------------------
	local currentId = deps.sessions:newId()

	-- Forward declaration so a memory row's ✕ callback can refresh the list (defined after refreshSessions).
	local refreshMemory: () -> ()
	local refreshSkills: () -> ()

	-- The transcript and the alternate views (sessions, memory, skills) are mutually exclusive; only one
	-- shows at a time. layoutChecklist() hides the checklist while any alternate view is up.
	local function updateViews()
		transcript.Visible = not (sessionList.Visible or memoryList.Visible or skillsList.Visible)
		histBtn.Text = if sessionList.Visible then "Back" else "History"
		memBtn.Text = if memoryList.Visible then "Back" else "Memory"
		skillsBtn.Text = if skillsList.Visible then "Back" else "Skills"
		layoutChecklist()
	end

	local function showSessions(show: boolean)
		sessionList.Visible = show
		if show then
			memoryList.Visible = false
			skillsList.Visible = false
		end
		updateViews()
	end

	local function showMemory(show: boolean)
		memoryList.Visible = show
		if show then
			sessionList.Visible = false
			skillsList.Visible = false
			refreshMemory()
		end
		updateViews()
	end

	local function showSkills(show: boolean)
		skillsList.Visible = show
		if show then
			sessionList.Visible = false
			memoryList.Visible = false
			refreshSkills()
		end
		updateViews()
	end

	-- Return to the transcript, closing ALL alternate views. Used by New chat / Send / open-session so
	-- the transcript is never left hidden behind a still-open Memory / History / Skills view (a Send
	-- would otherwise stream the whole reply into a hidden scroller).
	local function showTranscript()
		sessionList.Visible = false
		memoryList.Visible = false
		skillsList.Visible = false
		updateViews()
	end

	local function openSession(id: string)
		local data = deps.sessions:load(id)
		if not data then
			status.Text = "session not found"
			return
		end
		deps.conversation:load(data.title, data.messages)
		deps.taskList:load(data.tasks)
		currentId = id
		rebuildTranscript()
		renderChecklist(deps.taskList:snapshot())
		showTranscript()
		status.Text = "opened session"
	end

	local function refreshSessions()
		clearScroller(sessionList)
		rowOrder = 0
		local metas = deps.sessions:list()
		if #metas == 0 then
			local empty = Instance.new("TextLabel")
			empty.BackgroundTransparency = 1
			empty.Size = UDim2.new(1, -8, 0, 24)
			empty.TextColor3 = MUTED
			empty.TextSize = 13
			empty.Font = Enum.Font.Gotham
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.Text = "no saved chats yet"
			empty.Parent = sessionList
			return
		end
		for i, meta in metas do
			local b = button(meta.title .. "    " .. os.date("%Y-%m-%d %H:%M", meta.updatedAt))
			b.Size = UDim2.new(1, -8, 0, 32)
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.TextTruncate = Enum.TextTruncate.AtEnd
			b.LayoutOrder = i
			b.Parent = sessionList
			b.Activated:Connect(function()
				openSession(meta.id)
			end)
		end
	end

	-- Memory view --------------------------------------------------------------------------------
	local function addMemLabel(text: string, color: Color3)
		rowOrder += 1
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -8, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextColor3 = color
		label.TextSize = 12
		label.Font = Enum.Font.GothamBold
		label.Text = text
		label.LayoutOrder = rowOrder
		label.Parent = memoryList
	end

	local function addMemRow(scope: string, entry: any)
		rowOrder += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -8, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.LayoutOrder = rowOrder
		row.Parent = memoryList
		local txt = Instance.new("TextLabel")
		txt.BackgroundTransparency = 1
		txt.Size = UDim2.new(1, -26, 0, 0)
		txt.AutomaticSize = Enum.AutomaticSize.Y
		txt.TextWrapped = true
		txt.TextXAlignment = Enum.TextXAlignment.Left
		txt.TextYAlignment = Enum.TextYAlignment.Top
		txt.TextColor3 = TEXT
		txt.TextSize = 13
		txt.Font = Enum.Font.Gotham
		txt.Text = "#" .. tostring(entry.id) .. "  " .. tostring(entry.text)
		txt.Parent = row
		local x = button("✕")
		x.Size = UDim2.fromOffset(22, 22)
		x.Position = UDim2.new(1, -22, 0, 0)
		x.Parent = row
		x.Activated:Connect(function()
			deps.memory:forget(scope, entry.id)
			refreshMemory()
		end)
	end

	function refreshMemory()
		clearScroller(memoryList)
		rowOrder = 0
		addMemLabel("GLOBAL (every place)", MUTED)
		local g = deps.memory:list("global")
		if #g == 0 then
			addMemLabel("  (none)", MUTED)
		else
			for _, e in g do
				addMemRow("global", e)
			end
		end
		addMemLabel("THIS GAME", MUTED)
		local gm = deps.memory:list("game")
		if #gm == 0 then
			addMemLabel("  (none)", MUTED)
		else
			for _, e in gm do
				addMemRow("game", e)
			end
		end
	end

	-- Skills view --------------------------------------------------------------------------------
	local function addSkillHeader(text: string)
		rowOrder += 1
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -8, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.TextColor3 = MUTED
		label.TextSize = 12
		label.Font = Enum.Font.GothamBold
		label.Text = text
		label.LayoutOrder = rowOrder
		label.Parent = skillsList
	end

	local function addSkillRow(skill: any, deletable: boolean)
		rowOrder += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -8, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.LayoutOrder = rowOrder
		row.Parent = skillsList
		local txt = Instance.new("TextLabel")
		txt.BackgroundTransparency = 1
		txt.Size = UDim2.new(1, if deletable then -26 else 0, 0, 0)
		txt.AutomaticSize = Enum.AutomaticSize.Y
		txt.TextWrapped = true
		txt.TextXAlignment = Enum.TextXAlignment.Left
		txt.TextYAlignment = Enum.TextYAlignment.Top
		txt.TextColor3 = TEXT
		txt.TextSize = 13
		txt.Font = Enum.Font.Gotham
		txt.Text = tostring(skill.name) .. " — " .. tostring(skill.description)
		txt.Parent = row
		if deletable then
			local x = button("✕")
			x.Size = UDim2.fromOffset(22, 22)
			x.Position = UDim2.new(1, -22, 0, 0)
			x.Parent = row
			x.Activated:Connect(function()
				deps.skills:delete(skill.name)
				refreshSkills()
			end)
		end
	end

	function refreshSkills()
		clearScroller(skillsList)
		rowOrder = 0
		local builtins = deps.skills:listBuiltins()
		addSkillHeader("BUILD RECIPES")
		for _, s in builtins do
			if s.category ~= "working" then
				addSkillRow(s, false)
			end
		end
		addSkillHeader("WORKING SKILLS")
		for _, s in builtins do
			if s.category == "working" then
				addSkillRow(s, false)
			end
		end
		addSkillHeader("YOUR SKILLS")
		local user = deps.skills:listUser()
		if #user == 0 then
			addSkillHeader("  (none yet — save one with the create-skill skill)")
		else
			for _, s in user do
				addSkillRow(s, true)
			end
		end
	end

	-- Wiring -------------------------------------------------------------------------------------
	local cancelled = false

	saveBtn.Activated:Connect(function()
		local ok, reason = deps.config:set("proxyKey", keyBox.Text)
		status.Text = if ok then "key saved" else "rejected: " .. tostring(reason)
	end)

	histBtn.Activated:Connect(function()
		if sessionList.Visible then
			showSessions(false)
		else
			refreshSessions()
			showSessions(true)
		end
	end)

	memBtn.Activated:Connect(function()
		showMemory(not memoryList.Visible)
	end)

	skillsBtn.Activated:Connect(function()
		showSkills(not skillsList.Visible)
	end)

	newBtn.Activated:Connect(function()
		cancelled = true
		deps.conversation:clear()
		deps.taskList:clear()
		currentId = deps.sessions:newId()
		clearScroller(transcript)
		rowOrder = 0
		renderChecklist({})
		showTranscript()
		status.Text = "new chat"
	end)

	sendBtn.Activated:Connect(function()
		local text = taskBox.Text
		if text == "" then
			return
		end
		cancelled = false
		showTranscript()
		addRow(YOU, "You: " .. text)
		deps.agentLoop.send(
			deps.anthropic,
			deps.config,
			deps.systemPrompt,
			deps.conversation,
			deps.taskList,
			deps.memory,
			deps.skills,
			text,
			{
				onEvent = function(event: string, data: any)
					if event == "assistant_text" then
						addRow(TEXT, "Claude: " .. tostring(data))
						print("[agent] " .. tostring(data))
					elseif event == "tool_use" then
						status.Text = "running " .. tostring(data.name)
						addRow(MUTED, "[" .. tostring(data.name) .. "]")
						print("[agent] tool_use -> " .. tostring(data.name))
					elseif event == "tool_result" then
						print("[agent] tool_result (error=" .. tostring(data.isError) .. ")")
					elseif event == "iteration" then
						status.Text = "step " .. tostring(data.n) .. "/" .. tostring(data.max)
					elseif event == "notice" then
						addRow(MUTED, tostring(data))
					elseif event == "tasks" then
						renderChecklist(data)
					elseif event == "status" then
						status.Text = tostring(data)
					elseif event == "done" then
						status.Text = if data.stop == "max_iterations"
							then "step limit — say 'continue'"
							else "done"
						taskBox.Text = ""
						deps.sessions:save(deps.conversation, currentId, deps.taskList:snapshot())
					elseif event == "error" then
						status.Text = "error [" .. tostring(data.kind) .. "]"
						addRow(ERR, "[error] " .. tostring(data.message))
					end
				end,
				shouldCancel = function(): boolean
					return cancelled
				end,
			},
			deps.relay
		)
	end)

	stopBtn.Activated:Connect(function()
		cancelled = true
		status.Text = "stopping after current step..."
	end)

	-- Render any existing conversation + checklist — restores the visible chat after a re-mount (e.g.
	-- across a Studio play/edit transition that cleared the widget; the conversation + taskList live in
	-- deps, so they survive the blank).
	rebuildTranscript()
	renderChecklist(deps.taskList:snapshot())
end

return Widget
