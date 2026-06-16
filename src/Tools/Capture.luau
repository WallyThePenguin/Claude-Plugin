--!strict
-- Capture: the `capture` vision tool. A plugin can't read viewport pixels, so it asks the local
-- screenshot sidecar (sidecar/, 127.0.0.1:8389, token-authed) for a PNG of the Studio window and
-- hands it to Claude as a base64 IMAGE block so the model can actually SEE what it built and iterate
-- visually (GUIs, scenes, rigs, animation frames).
--
-- This is the ONE tool that returns STRUCTURED content (a tool_result blocks array) instead of a
-- plain string; AgentLoop forwards the array verbatim as the tool_result `content` (Anthropic accepts
-- a string OR a blocks array). On ANY failure it falls back to a STRING error (is_error=true) so the
-- loop is never left with a tool_use lacking a usable tool_result.
--
-- The sidecar URL + token live in Config; AgentLoop injects them via the dispatch `context`
-- (context.config). Capture stays decoupled from the Config module — it only duck-types the getters.

local HttpService = game:GetService("HttpService")

local Capture = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

-- Sidecar screenshot URL: ask for base64 text (b64=1) and percent-encode the window substring.
local function buildUrl(baseUrl: string, window: string): string
	return baseUrl .. "/screenshot?b64=1&window=" .. HttpService:UrlEncode(window)
end

local function runCapture(input: any, context: any): (any, boolean)
	local config = if type(context) == "table" then context.config else nil
	if config == nil then
		return "capture: internal error (no config available)", true
	end

	local token = config:getSidecarToken()
	if token == "" then
		return "capture: no sidecar token is set. Start the vision sidecar (sidecar/run.ps1) and "
			.. "paste the token it prints into the panel's 'sidecar token' field.",
			true
	end

	local args = if type(input) == "table" then input else {}
	local window = if type(args.window) == "string" and args.window ~= ""
		then args.window
		else "Roblox Studio"

	local baseUrl = config:getSidecarUrl()
	local options = {
		Url = buildUrl(baseUrl, window),
		Method = "GET",
		Headers = {
			["Authorization"] = "Bearer " .. token,
		},
	}

	-- RequestAsync is bimodal (same as Anthropic.request): it RAISES on transport / HTTP-disabled /
	-- server-only-context, and returns Success=false on a non-2xx response.
	local ok, res = pcall(function()
		return HttpService:RequestAsync(options)
	end)

	if not ok then
		local msg = string.lower(tostring(res))
		if string.find(msg, "not enabled", 1, true) then
			return "capture: HTTP requests are disabled. Enable 'Allow HTTP Requests' in Game "
				.. "Settings > Security.",
				true
		end
		if string.find(msg, "game server", 1, true) then
			-- HttpService is server-only; in a client-view playtest the plugin can't reach the sidecar.
			return "capture: HttpService is server-only — take screenshots from edit mode or the "
				.. "Studio Server view (the Client/Server dropdown).",
				true
		end
		return "capture: could not reach the vision sidecar at "
			.. baseUrl
			.. " — is it running? Start it with sidecar/run.ps1. ("
			.. tostring(res)
			.. ")",
			true
	end

	local response = res :: any
	if not response.Success then
		if response.StatusCode == 401 then
			return "capture: the sidecar rejected the token (401). Re-copy the token from "
				.. "sidecar/run.ps1 into the 'sidecar token' field and Save.",
				true
		end
		return "capture: the sidecar returned HTTP "
			.. tostring(response.StatusCode)
			.. ": "
			.. tostring(response.Body),
			true
	end

	-- Strip any stray surrounding whitespace (e.g. a trailing newline) defensively — Anthropic wants
	-- raw standard base64 and can reject the image otherwise. The sidecar emits clean base64, so this
	-- is just a guard at the API boundary.
	local data = (string.gsub(tostring(response.Body), "%s", ""))
	if data == "" then
		return "capture: the sidecar returned an empty image (try focusing Studio once and retry).",
			true
	end

	-- Structured tool_result content: a single base64 PNG image block. AgentLoop sets this array as
	-- the tool_result `content` so the model receives the screenshot it can look at.
	local blocks = {
		{
			type = "image",
			source = {
				type = "base64",
				media_type = "image/png",
				data = data,
			},
		},
	}
	return blocks, false
end

Capture.descriptors = {
	{
		name = "capture",
		description = "Take a SCREENSHOT of the Roblox Studio window and SEE it — the result is "
			.. "returned as an image you can look at. Use this to VISUALLY verify anything you build "
			.. "that has an appearance (GUIs, scenes, rigs, animation frames): check colors, layout, "
			.. "alignment, spacing, and framing, then adjust and capture again until it looks right. "
			.. "Requires the local vision sidecar to be running; if it isn't, capture returns an "
			.. "error explaining how to start it.",
		inputSchema = {
			type = "object",
			properties = {
				window = {
					type = "string",
					description = "Optional window-title substring to capture "
						.. "(default 'Roblox Studio').",
				},
			},
		},
		destructive = false,
		run = runCapture,
	},
} :: { Descriptor }

return Capture
