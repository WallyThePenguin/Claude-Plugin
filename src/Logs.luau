--!strict
-- Logs (M13): a ring buffer of Studio Output captured from LogService.MessageOut at plugin load.
-- Captures print/warn AND runtime SCRIPT ERRORS (with messages) — including during a playtest — so
-- the agent can read get_output to verify its scripts actually ran cleanly and self-correct without
-- the user having to point out errors.

local LogService = game:GetService("LogService")

local Logs = {}

export type Entry = { kind: string, text: string }

local MAX = 400
local buffer: { Entry } = {}

local function kindOf(messageType: Enum.MessageType): string
	if messageType == Enum.MessageType.MessageError then
		return "error"
	elseif messageType == Enum.MessageType.MessageWarning then
		return "warning"
	elseif messageType == Enum.MessageType.MessageInfo then
		return "info"
	end
	return "output"
end

LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
	table.insert(buffer, { kind = kindOf(messageType), text = message })
	if #buffer > MAX then
		table.remove(buffer, 1)
	end
end)

-- Most-recent-last list of up to `limit` entries (default 50), optionally only warnings/errors.
function Logs.recent(limit: number?, errorsOnly: boolean?): { Entry }
	local n = limit or 50
	local out: { Entry } = {}
	for i = #buffer, 1, -1 do
		local entry = buffer[i]
		if not errorsOnly or entry.kind == "error" or entry.kind == "warning" then
			table.insert(out, 1, entry)
			if #out >= n then
				break
			end
		end
	end
	return out
end

function Logs.clear()
	table.clear(buffer)
end

return Logs
