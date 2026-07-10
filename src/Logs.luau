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
-- Monotonic count of every line EVER captured (never decremented by ring-buffer eviction) — a cheap
-- change signal so pollers (DevBridge's log push) can skip re-sending when nothing new arrived.
local total = 0

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
	total += 1
	if #buffer > MAX then
		table.remove(buffer, 1)
	end
end)

-- Monotonic lines-ever-captured counter. Unequal across two reads = new output arrived between them.
function Logs.total(): number
	return total
end

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
	-- A clear IS a change: bump the counter so change-signal pollers push the emptied snapshot too.
	total += 1
end

return Logs
