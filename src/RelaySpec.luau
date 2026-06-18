--!strict
-- RelaySpec: in-Studio self-test for the PURE surface of the relay — context mode (in edit), the
-- relay/local tool classification (and that it matches the registered tools), and wrapAnthropic
-- routing. The host/client (live RemoteFunction across the two play DataModels) are LIVE-verified in
-- Studio, not here. Run via temporarily adding `require(script.RelaySpec).run()` to init.server.luau,
-- build, reopen Studio, read Output.

local Relay = require(script.Parent.Relay)
local Tools = require(script.Parent.Tools)

local M = {}

-- The 16 custom (locally-dispatchable) tools, partitioned by where they run in client-view play.
local EXPECTED_LOCAL = {
	"update_tasks",
	"remember",
	"forget",
	"use_skill",
	"save_skill",
	"delete_skill",
}
local EXPECTED_RELAY = {
	"run_luau",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"set_property",
	"create_instance",
	"capture",
	"dispatch_subagents",
	"dispatch_writers",
}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("mode() returns 'edit' when run in edit", function()
		local m = Relay.mode()
		if m ~= "edit" then
			return false, "got " .. tostring(m)
		end
		return true
	end)

	add("shouldRelayTool: plugin-only tools run LOCAL (false)", function()
		for _, n in EXPECTED_LOCAL do
			if Relay.shouldRelayTool(n) ~= false then
				return false, n .. " should be local"
			end
		end
		return true
	end)

	add("shouldRelayTool: DataModel/HTTP/dispatch tools RELAY (true)", function()
		for _, n in EXPECTED_RELAY do
			if Relay.shouldRelayTool(n) ~= true then
				return false, n .. " should relay"
			end
		end
		return true
	end)

	add("every EXPECTED_LOCAL name is a real registered tool", function()
		for _, n in EXPECTED_LOCAL do
			if Tools.get(n) == nil then
				return false, "not registered: " .. n
			end
		end
		return true
	end)

	add("every EXPECTED_RELAY name is a real registered tool", function()
		for _, n in EXPECTED_RELAY do
			if Tools.get(n) == nil then
				return false, "not registered: " .. n
			end
		end
		return true
	end)

	add("classification covers the whole custom registry (no drift)", function()
		-- Every registered custom tool must appear in exactly one of the two expected lists, so a new
		-- tool added without updating the split fails here.
		local known: { [string]: boolean } = {}
		for _, n in EXPECTED_LOCAL do
			known[n] = true
		end
		for _, n in EXPECTED_RELAY do
			known[n] = true
		end
		for _, schema in (Tools :: any).schemas(nil) do
			local name = schema.name
			-- Server-side web tools (web_search/web_fetch) have no descriptor and are never dispatched
			-- locally; skip them (Tools.get is nil for them).
			if Tools.get(name) ~= nil and not known[name] then
				return false, "unclassified registered tool: " .. tostring(name)
			end
		end
		return true
	end)

	add("wrapAnthropic routes sendMessage through client.http", function()
		local captured: any = nil
		local stub = {
			http = function(opts: any): any
				captured = opts
				return { ok = true, data = { content = {} } }
			end,
		}
		local wrapped = Relay.wrapAnthropic(stub)
		local res = wrapped:sendMessage({ messages = { "x" }, maxTokens = 7 })
		if type(res) ~= "table" or res.ok ~= true then
			return false, "sendMessage did not return the stub Result"
		end
		if type(captured) ~= "table" or captured.maxTokens ~= 7 then
			return false, "opts not forwarded to client.http"
		end
		return true
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== RelaySpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	local passed = total - failed
	print(
		"=== Summary: "
			.. tostring(passed)
			.. "/"
			.. tostring(total)
			.. " passed, "
			.. tostring(failed)
			.. " failed ==="
	)
	return { passed = failed == 0, total = total, failed = failed }
end

return M
