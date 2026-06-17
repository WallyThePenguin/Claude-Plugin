--!strict
-- Web: the web_fetch + web_search tools. They turn the plugin's existing HttpService egress into
-- first-class READ tools so the agent can read the Roblox docs (the system prompt points at
-- create.roblox.com/docs/... — fetch any page as its URL or append .md for clean markdown) and look
-- up APIs/solutions instead of guessing. Both are read-only (destructive=false) and are also handed
-- to read-only subagents (see Tools/Subagents READ_ONLY) so a research child can fan out.
--
-- HttpService is SERVER-ONLY: these work in edit / the Studio Server view, not a client-view playtest
-- (handled like Anthropic.request / Capture). RequestAsync is bimodal — it RAISES on transport /
-- HTTP-disabled / server-only-context, and returns Success=false on a non-2xx response.

local HttpService = game:GetService("HttpService")

local Web = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"web result not JSON-encodable"}'
end

-- Decode the handful of HTML entities worth handling.
local function decodeEntities(s: string): string
	s = (string.gsub(s, "&nbsp;", " "))
	s = (string.gsub(s, "&amp;", "&"))
	s = (string.gsub(s, "&lt;", "<"))
	s = (string.gsub(s, "&gt;", ">"))
	s = (string.gsub(s, "&quot;", '"'))
	s = (string.gsub(s, "&#39;", "'"))
	s = (string.gsub(s, "&#x27;", "'"))
	return s
end

-- Percent-decode a URL component (HttpService has UrlEncode but no UrlDecode).
local function urlDecode(s: string): string
	s = (string.gsub(s, "+", " "))
	s = (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
	return s
end

-- Heuristic: does this body look like an HTML document/fragment worth stripping?
local function looksLikeHtml(body: string): boolean
	local lower = string.lower(body)
	return string.find(lower, "<html", 1, true) ~= nil
		or string.find(lower, "<!doctype html", 1, true) ~= nil
		or string.find(lower, "<body", 1, true) ~= nil
		or string.find(lower, "<div", 1, true) ~= nil
		or string.find(lower, "<p>", 1, true) ~= nil
end

-- Unconditionally strip tags -> readable text (drop script/style blocks, tags, decode entities,
-- collapse whitespace). Used directly on title/snippet fragments by the DDG parser.
function Web.stripTags(s: string): string
	if type(s) ~= "string" then
		return ""
	end
	-- Drop <script>/<style> blocks WITH their contents (case-insensitive open/close).
	s = (string.gsub(s, "<[sS][cC][rR][iI][pP][tT].->.-</[sS][cC][rR][iI][pP][tT]%s*>", " "))
	s = (string.gsub(s, "<[sS][tT][yY][lL][eE].->.-</[sS][tT][yY][lL][eE]%s*>", " "))
	s = (string.gsub(s, "<!%-%-.-%-%->", " ")) -- comments
	-- Turn block-ish tags into newlines so structure survives.
	s = (string.gsub(s, "<[bB][rR]%s*/?%s*>", "\n"))
	s = (string.gsub(s, "</[pP]%s*>", "\n"))
	s = (string.gsub(s, "</[dD][iI][vV]%s*>", "\n"))
	s = (string.gsub(s, "</[lL][iI]%s*>", "\n"))
	s = (string.gsub(s, "</[hH][1-6]%s*>", "\n"))
	-- Strip every remaining tag, then decode entities and collapse whitespace.
	s = (string.gsub(s, "<[^>]*>", ""))
	s = decodeEntities(s)
	s = (string.gsub(s, "[ \t]+", " "))
	s = (string.gsub(s, "\n[ \t]+", "\n"))
	s = (string.gsub(s, "\n\n\n+", "\n\n"))
	s = (string.gsub(s, "^%s+", ""))
	return s
end

-- Strip HTML to readable text, but pass NON-HTML bodies (fetched .md / llms.txt / plain) through
-- unchanged so clean markdown is never mangled.
function Web.stripHtml(body: string): string
	if type(body) ~= "string" then
		return ""
	end
	if not looksLikeHtml(body) then
		return body
	end
	return Web.stripTags(body)
end

-- Parse a DuckDuckGo html.duckduckgo.com results page into {title,url,snippet} entries.
function Web.parseDdg(body: string, maxResults: number): { any }
	local results: { any } = {}
	for href, rawTitle in string.gmatch(body, 'class="result__a"[^>]-href="([^"]*)"[^>]*>(.-)</a>') do
		local url = href
		local uddg = string.match(href, "uddg=([^&]*)")
		if uddg ~= nil then
			url = urlDecode(uddg)
		elseif string.sub(href, 1, 2) == "//" then
			url = "https:" .. href
		end
		local title = (string.gsub(Web.stripTags(rawTitle), "^%s*(.-)%s*$", "%1"))
		table.insert(results, { url = url, title = title, snippet = "" })
		if #results >= maxResults then
			break
		end
	end
	-- Snippets are separate elements; zip them onto the results by order.
	local i = 0
	for rawSnip in string.gmatch(body, 'class="result__snippet"[^>]*>(.-)</a>') do
		i += 1
		if results[i] ~= nil then
			results[i].snippet = (string.gsub(Web.stripTags(rawSnip), "^%s*(.-)%s*$", "%1"))
		end
		if i >= #results then
			break
		end
	end
	return results
end

-- Shared RequestAsync wrapper: returns (ok, bodyOrErrText). Mirrors Anthropic.request's bimodal handling.
local function httpGet(url: string, headers: { [string]: string }?): (boolean, string, number?)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET", Headers = headers })
	end)
	if not ok then
		local msg = string.lower(tostring(res))
		if string.find(msg, "not enabled", 1, true) then
			return false,
				"HTTP requests are disabled. Enable 'Allow HTTP Requests' in Game Settings > Security."
		end
		if string.find(msg, "game server", 1, true) then
			return false,
				"HttpService is server-only — use this from edit mode or the Studio Server view (not a client-view playtest)."
		end
		return false, "request failed: " .. tostring(res)
	end
	local response = res :: any
	if not response.Success then
		return false, "HTTP " .. tostring(response.StatusCode), response.StatusCode
	end
	return true, tostring(response.Body)
end

local function runFetch(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local url = args.url
	if type(url) ~= "string" or url == "" then
		return "web_fetch requires { url = <http(s) url>, maxChars? = <int> }", true
	end
	if string.sub(url, 1, 7) ~= "http://" and string.sub(url, 1, 8) ~= "https://" then
		return "web_fetch: url must start with http:// or https://", true
	end

	local ok, body = httpGet(url)
	if not ok then
		return "web_fetch: " .. body, true
	end

	local hardCap = 20000
	if type(context) == "table" and context.config ~= nil then
		hardCap = context.config:getWebFetchMaxChars()
	end
	local want = hardCap
	if type(args.maxChars) == "number" and args.maxChars >= 1 then
		want = math.min(math.floor(args.maxChars), hardCap)
	end

	local text = Web.stripHtml(body)
	if #text > want then
		-- Back up off a partial UTF-8 char so truncation never splits a multi-byte sequence
		-- (continuation bytes are 0x80-0xBF). string.byte returns nil past the end -> stop.
		local cut = want
		while cut > 0 do
			local b = string.byte(text, cut + 1)
			if b ~= nil and b >= 0x80 and b < 0xC0 then
				cut -= 1
			else
				break
			end
		end
		text = string.sub(text, 1, cut) .. "\n…[truncated]"
	end
	return text, false
end

local function runSearch(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local query = args.query
	if type(query) ~= "string" or query == "" then
		return "web_search requires { query = <string>, maxResults? = <int> }", true
	end

	local cap = 5
	if type(context) == "table" and context.config ~= nil then
		cap = context.config:getWebSearchMaxResults()
	end
	local want = cap
	if type(args.maxResults) == "number" and args.maxResults >= 1 then
		want = math.min(math.floor(args.maxResults), cap)
	end

	-- NOTE: Roblox HttpService forbids setting the User-Agent header ("Header 'User-Agent' is not
	-- allowed!"), so we send with Roblox's default UA. DuckDuckGo may serve or block it — web_search is
	-- best-effort either way.
	local url = "https://html.duckduckgo.com/html/?q=" .. HttpService:UrlEncode(query)
	local ok, body = httpGet(url)
	if not ok then
		return "web_search: " .. body, true
	end

	local results = Web.parseDdg(body, want)
	if #results == 0 then
		return encodeResult({
			ok = true,
			query = query,
			results = {},
			note = "no results parsed (DuckDuckGo may have blocked or changed its markup); "
				.. "try web_fetch with a known URL, e.g. the Roblox docs.",
		}),
			false
	end
	return encodeResult({ ok = true, query = query, results = results }), false
end

Web.descriptors = {
	{
		name = "web_fetch",
		description = "Fetch a web page or document by URL and return its text (HTML is stripped to "
			.. "readable text; markdown/plain bodies pass through). Use it to READ the Roblox docs — "
			.. "fetch https://create.roblox.com/docs/reference/engine/llms.txt for the API index, then "
			.. "any page's URL (append .md for clean markdown) — and to read pages found via "
			.. "web_search. Prefer fetching the official docs over guessing an API. Server-only (works "
			.. "in edit / the Server view). Large pages are truncated.",
		inputSchema = {
			type = "object",
			properties = {
				url = { type = "string", description = "Absolute http(s) URL to fetch." },
				maxChars = {
					type = "integer",
					description = "Optional cap on returned characters (clamped to the config max).",
				},
			},
			required = { "url" },
		},
		destructive = false,
		run = runFetch,
	},
	{
		name = "web_search",
		description = "Search the web (DuckDuckGo) and return the top results as {title, url, "
			.. "snippet}. Use it to find docs/solutions, then web_fetch a result's URL to read it. "
			.. "Best-effort — if the search is blocked it returns a note; fall back to web_fetch with a "
			.. "known URL. Server-only.",
		inputSchema = {
			type = "object",
			properties = {
				query = { type = "string", description = "Search query." },
				maxResults = {
					type = "integer",
					description = "Optional max results (clamped to the config max).",
				},
			},
			required = { "query" },
		},
		destructive = false,
		run = runSearch,
	},
} :: { Descriptor }

return Web
