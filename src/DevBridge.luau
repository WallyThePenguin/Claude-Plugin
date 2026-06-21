--!strict
-- DevBridge: lets Claude Code (the shell) drive the plugin over the localhost sidecar instead of
-- computer-use. EDIT-only poll loop: each tick pushes recent Output logs and pulls one queued command —
-- `tool` (Tools.dispatch), `luau` (the run_luau tool), or `prompt` (AgentLoop.send on the shared
-- conversation). Pure helpers (serialize/accumulate) are unit-tested in DevBridgeSpec; the loop + HTTP
-- are live-verified. See the dev-bridge design spec. Localhost-only, plugin-only, never in a shipped game.

local DevBridge = {}

export type Result = { reply: string, tools: { any }, error: string?, done: boolean }

-- Tool/Luau content -> a string for the shell. A blocks array (e.g. capture's image) is summarized;
-- fetch the actual PNG via GET /captures.
function DevBridge.serializeContent(content: any): string
	if type(content) == "string" then
		return content
	end
	if type(content) == "table" then
		return "[non-text tool content (e.g. a viewport capture) — fetch it via GET /captures]"
	end
	return tostring(content)
end

function DevBridge.newResult(): Result
	return { reply = "", tools = {}, error = nil, done = false }
end

-- Fold one AgentLoop event into a prompt-mode result (used as the capturing callback's body).
function DevBridge.accumulate(result: Result, event: string, data: any)
	if event == "assistant_text" then
		local text = tostring(data)
		result.reply = if result.reply == "" then text else result.reply .. "\n" .. text
	elseif event == "tool_result" then
		local d = if type(data) == "table" then data else {}
		table.insert(result.tools, {
			name = tostring(d.name),
			isError = d.isError == true,
			text = tostring(d.text),
		})
	elseif event == "error" then
		result.error = if type(data) == "table" then tostring(data.message) else tostring(data)
		result.done = true
	elseif event == "done" then
		result.done = true
	end
end

return DevBridge
