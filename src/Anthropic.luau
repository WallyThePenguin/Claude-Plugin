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
		Body = HttpService:JSONEncode(body),
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
