--!strict
-- StoreClient: the plugin's client for the sidecar's file-backed knowledge store (/store API —
-- learnings archive, durable skills, factory staging). The store is GIT-VERSIONED on disk, so
-- everything written here is diffable/revertable; the plugin-settings stores remain the small
-- always-on caches. All calls are TOTAL (pcall'd HTTP, (result, err) returns) and fail-open:
-- callers append an honest note and keep working when the sidecar is down.

local HttpService = game:GetService("HttpService")

local StoreClient = {}

-- ---- pure ----

-- Slug a free-form name (skill name, category) into a store id: lowercase, [a-z0-9-], <=64,
-- no leading/trailing dashes. Returns nil when nothing survives.
function StoreClient.slug(name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local s = string.lower(name)
	s = string.gsub(s, "[^a-z0-9]+", "-")
	s = string.gsub(s, "^%-+", "")
	s = string.gsub(s, "%-+$", "")
	if s == "" then
		return nil
	end
	return string.sub(s, 1, 64)
end

-- ---- impure (sidecar HTTP; total) ----

local function baseUrl(config: any): (string?, string?)
	if config == nil then
		return nil, "no config available"
	end
	local ok, url = pcall(function(): string
		return config:getSidecarUrl()
	end)
	if not ok or type(url) ~= "string" or url == "" then
		return nil, "no sidecar url"
	end
	return url, nil
end

local function request(config: any, method: string, path: string, body: any?): (any?, string?)
	local base, err = baseUrl(config)
	if base == nil then
		return nil, err
	end
	local opts: { [string]: any } = { Url = base .. path, Method = method }
	if body ~= nil then
		opts.Headers = { ["Content-Type"] = "application/json" }
		opts.Body = HttpService:JSONEncode(body)
	end
	local okReq, res = pcall(function()
		return HttpService:RequestAsync(opts)
	end)
	if not okReq then
		return nil, "sidecar unreachable (" .. tostring(res) .. ")"
	end
	local r = res :: any
	if not r.Success then
		return nil, "sidecar HTTP " .. tostring(r.StatusCode) .. ": " .. tostring(r.Body)
	end
	local okDec, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not okDec then
		return nil, "bad store response"
	end
	return payload, nil
end

-- Read an item; (body, nil) / (nil, "not found") / (nil, err).
function StoreClient.get(config: any, kind: string, id: string): (any?, string?)
	local payload, err = request(config, "GET", "/store/" .. kind .. "/" .. id)
	if payload == nil and err ~= nil and string.find(err, "404", 1, true) ~= nil then
		return nil, "not found"
	end
	return payload, err
end

-- List a kind; ({items}, nil) / (nil, err).
function StoreClient.list(config: any, kind: string): (any?, string?)
	local payload, err = request(config, "GET", "/store/" .. kind)
	if payload == nil then
		return nil, err
	end
	return (payload :: any).items, nil
end

-- Write an item; (true, nil) / (false, err).
function StoreClient.put(config: any, kind: string, id: string, body: any): (boolean, string?)
	local payload, err = request(config, "POST", "/store/" .. kind .. "/" .. id, body)
	return payload ~= nil, err
end

-- Delete an item; (true, nil) / (false, err). Deleting an absent item still succeeds.
function StoreClient.remove(config: any, kind: string, id: string): (boolean, string?)
	local payload, err = request(config, "DELETE", "/store/" .. kind .. "/" .. id)
	return payload ~= nil, err
end

return StoreClient
