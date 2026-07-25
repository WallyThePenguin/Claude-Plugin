--!strict
-- DevBridgeSpec: in-Studio self-test for the PURE DevBridge helpers. Run via temporarily adding
-- `require(script.DevBridgeSpec).run()` to init.server.luau, build, reopen Studio, read Output.

local DevBridge = require(script.Parent.DevBridge)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("serializeContent passes a string through", function()
		return DevBridge.serializeContent("hello") == "hello"
	end)

	add("serializeContent summarizes a blocks array", function()
		local s = DevBridge.serializeContent({ { type = "image" } })
		return string.find(s, "GET /captures", 1, true) ~= nil
	end)

	add("accumulate joins assistant_text and records tool_result", function()
		local r = DevBridge.newResult()
		DevBridge.accumulate(r, "assistant_text", "line1")
		DevBridge.accumulate(r, "assistant_text", "line2")
		DevBridge.accumulate(r, "tool_result", { name = "ik_reach", isError = false, text = "ok" })
		return r.reply == "line1\nline2"
			and #r.tools == 1
			and r.tools[1].name == "ik_reach"
			and r.tools[1].isError == false
			and not r.done
	end)

	add("accumulate marks done on done", function()
		local r = DevBridge.newResult()
		DevBridge.accumulate(r, "done", { stop = "end_turn" })
		return r.done and r.error == nil
	end)

	add("accumulate captures an error and marks done", function()
		local r = DevBridge.newResult()
		DevBridge.accumulate(r, "error", { kind = "busy", message = "agent already running" })
		return r.done and r.error == "agent already running"
	end)

	add("contextBanner: clean edit -> empty (no noise)", function()
		return DevBridge.contextBanner(true, false, true, true) == ""
	end)

	-- Team Create connects as a CLIENT (IsServer=false/IsClient=true) with a collaborator LocalPlayer,
	-- but it is GENUINE edit (IsEdit=true, not running) — the guard MUST stay silent (no false positive).
	add("contextBanner: Team Create edit (client + IsEdit, not running) -> empty", function()
		return DevBridge.contextBanner(true, false, false, true) == ""
	end)

	add(
		"contextBanner: a running playtest warns + names the server role + the verify nudge",
		function()
			local s = DevBridge.contextBanner(false, true, true, false)
			return string.find(s, "WARN run-context", 1, true) ~= nil
				and string.find(s, "PLAYTEST", 1, true) ~= nil
				and string.find(s, "role=server", 1, true) ~= nil
				and string.find(s, "VERIFY with a capture", 1, true) ~= nil
		end
	)

	add("contextBanner: a play CLIENT (running, not edit) warns NOT-edit + client", function()
		local s = DevBridge.contextBanner(false, true, false, true)
		return string.find(s, "NOT the edit DataModel", 1, true) ~= nil
			and string.find(s, "role=client", 1, true) ~= nil
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[DevBridgeSpec] PASS " .. c.name)
		else
			warn("[DevBridgeSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[DevBridgeSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
