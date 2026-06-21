--!strict
-- Anthropic (M2): the HTTP client for the proxy's Anthropic-compatible /v1/messages.
-- M2 covers request/sendMessage/ping; the agent loop (tool_use dispatch) arrives in M6.
-- Speaks native Anthropic Messages, non-streaming (RequestAsync returns the full body).

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)

local Anthropic = {}
Anthropic.__index = Anthropic

-- Result of a single HTTP call. `ok` true -> `data` is the decoded JSON body.
-- `ok` false -> `kind` classifies the failure and `message` is human/Claude-facing.
export type Result = {
	ok: boolean,
	data: any?,
	kind: string?, -- auth | httpDisabled | transport | http | decode
	status: number?, -- HTTP status code (http errors only)
	message: string?,
}

export type SendOpts = {
	messages: { any },
	model: string?,
	maxTokens: number?,
	system: string?,
	tools: { any }?,
	toolChoice: any?,
}

export type Anthropic = typeof(setmetatable(
	{} :: {
		_config: Config.Config,
	},
	Anthropic
))

function Anthropic.new(config: Config.Config): Anthropic
	local self = setmetatable({}, Anthropic)
	self._config = config
	return self
end

-- Roblox's HttpService:JSONEncode emits "[]" for an EMPTY Lua table, but Anthropic requires a
-- tool_use block's `input` to be a JSON OBJECT. A no-argument tool call (e.g. `capture` or
-- `get_output` invoked with no args) arrives decoded as an empty table and, echoed back verbatim,
-- would re-encode to "[]" — which the API rejects with
-- `tool_use.input: Input should be an object`. Fix it at the encode boundary, generically for every
-- tool: temporarily swap each empty/absent tool_use input for a sentinel STRING, JSONEncode, restore
-- the originals (so the live conversation history is never mutated — the swap is invisible outside
-- this synchronous call), then splice the quoted sentinel back to a literal "{}".
-- The sentinel is plain ASCII (JSONEncode won't escape it) and distinctive enough that a verbatim
-- collision in real content is not a practical concern.
local EMPTY_OBJECT_SENTINEL = "@@studio_agent_empty_object_sentinel@@"

local function encodeBody(body: { [string]: any }): string
	-- Each restore records an (object, key) whose empty/absent value we swapped for the sentinel, so
	-- the original is put back after encoding (the live conversation + tool defs are never left mutated).
	local restores: { { obj: any, key: string, old: any } } = {}
	local function swapEmpty(obj: any, key: string)
		local v = obj[key]
		if v == nil or (type(v) == "table" and next(v) == nil) then
			table.insert(restores, { obj = obj, key = key, old = v })
			obj[key] = EMPTY_OBJECT_SENTINEL
		end
	end

	-- (1) tool_use blocks in messages: a no-arg call echoes back an empty `input`.
	local messages = body.messages
	if type(messages) == "table" then
		for _, msg in messages do
			if type(msg) == "table" and type(msg.content) == "table" then
				for _, block in msg.content do
					if type(block) == "table" and block.type == "tool_use" then
						swapEmpty(block, "input")
					end
				end
			end
		end
	end

	-- (2) tool DEFINITIONS: a no-arg tool (e.g. `capture`) declares `input_schema.properties = {}`,
	-- which Anthropic requires to be a JSON object, not []. (Server tools carry no input_schema.)
	local tools = body.tools
	if type(tools) == "table" then
		for _, tool in tools do
			if type(tool) == "table" and type(tool.input_schema) == "table" then
				swapEmpty(tool.input_schema, "properties")
			end
		end
	end

	local encoded = HttpService:JSONEncode(body)
	for _, r in restores do
		r.obj[r.key] = r.old
	end
	return (string.gsub(encoded, '"' .. EMPTY_OBJECT_SENTINEL .. '"', "{}"))
end

-- One POST to {baseUrl}/v1/messages. Handles RequestAsync's bimodal failures:
-- it RAISES on transport/HTTP-disabled (pcall), and returns Success=false on non-2xx.
-- Never throws; never logs the proxy key.
function Anthropic.request(self: Anthropic, body: { [string]: any }): Result
	local proxyKey = self._config:getProxyKey()
	if proxyKey == "" then
		return {
			ok = false,
			kind = "auth",
			message = "proxy key not set (open settings and paste it)",
		}
	end

	local options = {
		Url = self._config:getBaseUrl() .. "/v1/messages",
		Method = "POST",
		Headers = {
			["Authorization"] = "Bearer " .. proxyKey,
			["anthropic-version"] = "2023-06-01",
			["content-type"] = "application/json",
		},
		Body = encodeBody(body),
	}

	local ok, res = pcall(function()
		return HttpService:RequestAsync(options)
	end)

	if not ok then
		-- RequestAsync raised: HTTP disabled, network failure, or timeout.
		local msg = tostring(res)
		if string.find(string.lower(msg), "not enabled", 1, true) then
			return {
				ok = false,
				kind = "httpDisabled",
				message = "Enable 'Allow HTTP Requests' in Game Settings > Security.",
			}
		end
		if string.find(string.lower(msg), "game server", 1, true) then
			-- HttpService is server-only; in an F5 playtest the plugin is in the CLIENT context.
			-- Not retryable — retrying in the same context won't help.
			return {
				ok = false,
				kind = "context",
				message = "HttpService is server-only. During a playtest switch Studio to the Server "
					.. "view (the Client/Server dropdown), or use the agent in edit mode.",
			}
		end
		return { ok = false, kind = "transport", message = msg }
	end

	local response = res :: any
	if not response.Success then
		-- Non-2xx: parse the Anthropic error envelope, but tolerate a non-JSON body.
		local message = tostring(response.Body)
		local okDecode, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if okDecode and type(decoded) == "table" then
			local err = (decoded :: any).error
			if type(err) == "table" and type(err.message) == "string" then
				message = err.message
			end
		end
		return { ok = false, kind = "http", status = response.StatusCode, message = message }
	end

	local okDecode, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okDecode then
		return { ok = false, kind = "decode", message = "could not decode response body" }
	end
	return { ok = true, data = decoded }
end

-- Assemble a Messages request body from opts (model/max_tokens default from Config;
-- system/tools omitted when nil) and send it.
function Anthropic.sendMessage(self: Anthropic, opts: SendOpts): Result
	local body: { [string]: any } = {
		model = if opts.model ~= nil then opts.model else self._config:getModel(),
		max_tokens = if opts.maxTokens ~= nil then opts.maxTokens else self._config:getMaxTokens(),
		messages = opts.messages,
	}
	if opts.system ~= nil then
		body.system = opts.system
	end
	if opts.tools ~= nil then
		body.tools = opts.tools
	end
	if opts.toolChoice ~= nil then
		body.tool_choice = opts.toolChoice
	end
	return self:request(body)
end

-- Concatenate the text blocks of a Messages response into a single string.
local function collectText(data: any): string
	if type(data) ~= "table" or type(data.content) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	for _, block in ipairs(data.content) do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			table.insert(parts, block.text)
		end
	end
	return table.concat(parts, "")
end

export type StructuredOpts = { messages: { any }, tool: { [string]: any }, maxTokens: number? }

-- Force a single tool call (structured output). Sends tools={tool} + tool_choice={type="tool",name}.
-- Returns (input, rawText, result):
--   input   = the forced tool's `input` table if the model called it (the structured result), else nil;
--   rawText = the assistant's text (for the caller's JSON-from-text fallback) when no tool_use came back
--             (e.g. a proxy that ignores tool_choice);
--   result  = the underlying Result (for error handling when ok=false).
function Anthropic.requestStructured(self: Anthropic, opts: StructuredOpts): (any?, string?, Result)
	local res = self:sendMessage({
		messages = opts.messages,
		maxTokens = opts.maxTokens,
		tools = { opts.tool },
		toolChoice = { type = "tool", name = opts.tool.name },
	})
	if not res.ok then
		return nil, nil, res
	end
	local data = res.data
	if type(data) == "table" and type(data.content) == "table" then
		for _, block in ipairs(data.content) do
			if
				type(block) == "table"
				and block.type == "tool_use"
				and type(block.input) == "table"
			then
				return block.input, nil, res
			end
		end
	end
	return nil, collectText(data), res
end

-- A no-tools smoke test. Runs under task.spawn so the caller (UI button) never yields.
-- Calls onResult(result, text) on the main thread when done.
function Anthropic.ping(self: Anthropic, promptText: string, onResult: ((Result, string) -> ())?)
	task.spawn(function()
		local res = self:sendMessage({
			messages = { { role = "user", content = promptText } },
			maxTokens = 256,
		})
		local text = if res.ok then collectText(res.data) else ""
		if res.ok then
			print("[StudioAgent ping] " .. text)
		else
			warn(
				"[StudioAgent ping] error [" .. tostring(res.kind) .. "]: " .. tostring(res.message)
			)
		end
		if onResult then
			onResult(res, text)
		end
	end)
end

return Anthropic
