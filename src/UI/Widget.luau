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
}

local TEXT = Color3.fromRGB(225, 225, 228)
local MUTED = Color3.fromRGB(150, 150, 155)
local YOU = Color3.fromRGB(120, 170, 255)
local ERR = Color3.fromRGB(255, 120, 120)
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

	-- Control row.
	local newBtn = button("New chat")
	newBtn.Size = UDim2.fromOffset(76, 26)
	newBtn.Position = UDim2.fromOffset(0, 32)
	newBtn.Parent = root
	local histBtn = button("History")
	histBtn.Size = UDim2.fromOffset(70, 26)
	histBtn.Position = UDim2.fromOffset(82, 32)
	histBtn.Parent = root
	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -158, 0, 26)
	status.Position = UDim2.fromOffset(158, 32)
	status.TextColor3 = MUTED
	status.TextSize = 12
	status.Font = Enum.Font.Gotham
	status.TextXAlignment = Enum.TextXAlignment.Right
	status.TextTruncate = Enum.TextTruncate.AtEnd
	status.Text = ""
	status.Parent = root

	-- Main area (flexes between the control row at y=64 and the input row at the bottom).
	local INPUT_H = 70
	local function scroller(): ScrollingFrame
		local sf = Instance.new("ScrollingFrame")
		sf.Size = UDim2.new(1, 0, 1, -(64 + INPUT_H + 4))
		sf.Position = UDim2.fromOffset(0, 64)
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
			if child:IsA("GuiButton") or child:IsA("TextLabel") then
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

	local function showSessions(show: boolean)
		sessionList.Visible = show
		transcript.Visible = not show
		histBtn.Text = if show then "Back" else "History"
	end

	local function openSession(id: string)
		local data = deps.sessions:load(id)
		if not data then
			status.Text = "session not found"
			return
		end
		deps.conversation:load(data.title, data.messages)
		currentId = id
		rebuildTranscript()
		showSessions(false)
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

	newBtn.Activated:Connect(function()
		cancelled = true
		deps.conversation:clear()
		currentId = deps.sessions:newId()
		clearScroller(transcript)
		rowOrder = 0
		showSessions(false)
		status.Text = "new chat"
	end)

	sendBtn.Activated:Connect(function()
		local text = taskBox.Text
		if text == "" then
			return
		end
		cancelled = false
		showSessions(false)
		addRow(YOU, "You: " .. text)
		deps.agentLoop.send(
			deps.anthropic,
			deps.config,
			deps.systemPrompt,
			deps.conversation,
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
					elseif event == "status" then
						status.Text = tostring(data)
					elseif event == "done" then
						status.Text = "done"
						taskBox.Text = ""
						deps.sessions:save(deps.conversation, currentId)
					elseif event == "error" then
						status.Text = "error [" .. tostring(data.kind) .. "]"
						addRow(ERR, "[error] " .. tostring(data.message))
					end
				end,
				shouldCancel = function(): boolean
					return cancelled
				end,
			}
		)
	end)

	stopBtn.Activated:Connect(function()
		cancelled = true
		status.Text = "stopping after current step..."
	end)
end

return Widget
