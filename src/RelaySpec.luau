--!strict
-- RelaySpec: in-Studio self-test for the PURE surface of the relay — context mode (in edit), the
-- relay/local tool classification (and that it matches the registered tools), and wrapAnthropic
-- routing. The host/client (live RemoteFunction across the two play DataModels) are LIVE-verified in
-- Studio, not here. Run via temporarily adding `require(script.RelaySpec).run()` to init.server.luau,
-- build, reopen Studio, read Output.

local Relay = require(script.Parent.Relay)
local Tools = require(script.Parent.Tools)

local M = {}

-- The custom (locally-dispatchable) tools, partitioned by where they run in client-view play. Must match
-- Relay.LOCAL_TOOLS: plugin/panel-state-only tools run LOCAL; everything else relays to the server copy.
local EXPECTED_LOCAL = {
	"update_tasks",
	"remember",
	"forget",
	"use_skill",
	"save_skill",
	"delete_skill",
	"use_rubric",
	"evaluate",
	"learn",
	"unlearn",
	"camera_focus",
	"camera_orbit",
	"camera_release",
}
local EXPECTED_RELAY = {
	"run_luau",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"set_property",
	"create_instance",
	"destroy_instance",
	"place_relative",
	"generate_mesh",
	"author_mesh",
	"save_mesh",
	"paint_texture",
	"make_tool",
	"grip_tool",
	"capture",
	"capture_angles",
	"capture_animation",
	"dispatch_subagents",
	"dispatch_writers",
	"spawn_rig",
	"get_rig",
	"pose_joint",
	"reset_pose",
	"show_skeleton",
	"ik_reach",
	"add_keyframe",
	"list_clip",
	"remove_keyframe",
	"clear_clip",
	"export_animation",
	"import_animation",
	"bind_animation",
	"bind_behavior",
	"bind_hitbox",
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

	add("unwrapHttp: success envelope passes the server Result through", function()
		local r = Relay.unwrapHttp(
			true,
			{ kind = "http", result = { ok = true, data = { content = {} } } }
		)
		if type(r) ~= "table" or r.ok ~= true then
			return false, "did not pass the Result through"
		end
		return true
	end)

	add("unwrapHttp: a transient server Result passes through (for Retry)", function()
		local r = Relay.unwrapHttp(
			true,
			{ kind = "http", result = { ok = false, kind = "http", status = 503 } }
		)
		if r.ok ~= false or r.kind ~= "http" or r.status ~= 503 then
			return false, "transient Result not preserved"
		end
		return true
	end)

	add("unwrapHttp: an error envelope surfaces the real message, non-transient", function()
		local r = Relay.unwrapHttp(true, { kind = "error", message = "boom" })
		if r.ok ~= false or r.kind ~= "relay" then
			return false, "expected kind=relay, got " .. tostring(r.kind)
		end
		if string.find(tostring(r.message), "boom", 1, true) == nil then
			return false, "real message lost"
		end
		return true
	end)

	add("unwrapHttp: a broken transport falls back to 'switch view' (context)", function()
		local r = Relay.unwrapHttp(false, "InvokeServer failed")
		if r.ok ~= false or r.kind ~= "context" then
			return false, "expected kind=context, got " .. tostring(r.kind)
		end
		return true
	end)

	add("unwrapTool: tool envelope returns (content, isError)", function()
		local content, isError =
			Relay.unwrapTool(true, { kind = "tool", content = "hi", isError = false })
		return content == "hi" and isError == false
	end)

	add("unwrapTool: a tool is_error envelope is preserved", function()
		local content, isError =
			Relay.unwrapTool(true, { kind = "tool", content = "bad", isError = true })
		return content == "bad" and isError == true
	end)

	add("unwrapTool: an error envelope surfaces the real message as is_error", function()
		local content, isError = Relay.unwrapTool(true, { kind = "error", message = "boom" })
		return isError == true and string.find(tostring(content), "boom", 1, true) ~= nil
	end)

	add("unwrapTool: a broken transport falls back to is_error 'switch view'", function()
		local content, isError = Relay.unwrapTool(false, nil)
		return isError == true and string.find(tostring(content), "Server view", 1, true) ~= nil
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
