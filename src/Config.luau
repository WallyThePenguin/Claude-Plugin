--!strict
-- Config (M1): typed wrapper over plugin:SetSetting/GetSetting.
-- Single source of truth for connection + agent-loop settings. Persisted values
-- are merged over hard DEFAULTS so a fresh install (or a missing key) always
-- resolves to a sane value. Never prints or logs the proxyKey.

export type ConfigValue = string | number | boolean

-- All known setting keys, with their hard defaults. M11 retry/confirm defaults
-- are included now to avoid later schema churn.
-- baseUrl defaults to 127.0.0.1:8318 — the local end of the SSH tunnel to hecate's CLIProxyAPI
-- (proxy/tunnel.ps1). The local docker proxy (proxy/docker-compose.yml) is on 8319 as a fallback.
-- 2026-07-03: hecate's proxy was redeployed (new image) and serves claude-fable-5.
-- 2026-07-04: default model switched to claude-opus-4-8 at the user's request (do NOT use
-- fable-5 as the primary). The fallback chain (agent_loop MODEL_FALLBACKS) filters out the
-- active model, so with opus-4-8 primary the only fallback left is opus-4-7 — fable-5 is out
-- of the loop entirely. NOTE: every
-- CLIProxyAPI subscription-OAuth daemon (hecate's AND a fresh local one) STRIPS the client `system`
-- field and injects its own Claude Code prompt — verified live. So the plugin delivers its
-- SystemPrompt + recalled memory as a LEADING MESSAGE instead (AgentLoop), which passes through any
-- such proxy. The proxy choice therefore no longer affects prompt delivery.
local DEFAULTS = {
	baseUrl = "http://127.0.0.1:8318",
	proxyKey = "",
	model = "claude-opus-4-8",
	maxTokens = 8192,
	-- Step budget per Send. Vision tasks ("build, capture, adjust, capture again…") burn several
	-- steps per iterate-cycle, so this is generous; hitting it now ends gracefully + resumable
	-- (say "continue") rather than discarding the turn.
	maxIterations = 40,
	confirmDestructive = true,
	retryMaxAttempts = 4,
	retryBaseDelay = 1.0,
	retryMaxDelay = 30.0,
	-- Vision sidecar (the `capture` tool): localhost screenshot server (no auth — 127.0.0.1-only).
	sidecarUrl = "http://127.0.0.1:8389",
	-- Context auto-compaction. contextWindow is a WORKING-SET BUDGET, not the model's true window
	-- (which is far larger): the loop is non-streaming and uncached, so every step re-pays the whole
	-- resident prompt — a smaller working set is strictly faster/cheaper, and the model window above
	-- it leaves the summarization call head-room. Compact triggers at window * threshold (~160k).
	contextWindow = 200000,
	compactThreshold = 0.8, -- compact when last prompt >= window * this (0 < x < 1)
	keepRecentMessages = 6, -- verbatim tail length kept when compacting
	imagesKept = 14, -- recent images kept in live context (older ones pruned) — must hold reference photos (get_references, up to 4) PLUS a full all-sides orbit (capture_angles count 5-6) or a 5-6 frame filmstrip with margin; at 6, one default capture_angles evicted every reference and the mandated photos-vs-capture comparison died
	-- Subagents (dispatch_subagents).
	subagentModel = "claude-sonnet-4-6", -- children run on the cheaper/faster model
	subagentMaxParallel = 4, -- max children per dispatch (excess truncated + reported)
	subagentMaxIterations = 15, -- per-child step cap
	-- Parallel writers (dispatch_writers).
	writerModel = "claude-sonnet-4-6", -- focused partitioned tasks; bump to opus for accuracy
	writerMaxParallel = 3, -- max writer children per dispatch (excess truncated + reported)
	writerMaxIterations = 20, -- per-child step cap
	-- Web access (Anthropic SERVER-SIDE web_search/web_fetch). `max_uses` bounds calls per turn.
	webSearchMaxUses = 5, -- max server-side web_search calls per turn
	webFetchMaxUses = 5, -- max server-side web_fetch calls per turn
	-- Camera-lock rig: when true, draw debug gizmos (orbit sphere/camera/pivot). Default off.
	cameraRigDebug = false,
	-- Dev bridge (DevBridge.luau): lets Claude Code drive the plugin from the shell via the sidecar.
	-- EDIT-only + localhost-only, so default-on (nothing to toggle); set false to disable.
	devBridge = true,
	devBridgePollInterval = 1.5, -- seconds between bridge poll ticks
}

-- Allowed models. Never Haiku.
local MODELS = { "claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6" }

local KEY_PREFIX = "StudioAgent_"

local Config = {}
Config.__index = Config

Config.DEFAULTS = DEFAULTS
Config.MODELS = MODELS
Config.KEY_PREFIX = KEY_PREFIX

export type Config = typeof(setmetatable(
	{} :: {
		_plugin: Plugin,
	},
	Config
))

local function isKnownKey(key: string): boolean
	return (DEFAULTS :: { [string]: ConfigValue })[key] ~= nil
end

local function isAllowedModel(value: string): boolean
	for _, allowed in MODELS do
		if allowed == value then
			return true
		end
	end
	return false
end

-- Clamp an integer-ish number to [min, max] (inclusive). Non-finite or NaN
-- values are coerced to the provided fallback.
local function clampNumber(value: number, min: number, max: number, fallback: number): number
	if value ~= value then
		return fallback
	end
	if value < min then
		return min
	end
	if value > max then
		return max
	end
	return value
end

function Config.new(plugin: Plugin): Config
	local self = setmetatable({}, Config)
	self._plugin = plugin
	return self
end

-- Resolve a single key: persisted value if present, else the hard default.
-- Uses an explicit nil check so a persisted `false`/`0` is not dropped.
function Config.get(self: Config, key: string): ConfigValue?
	local default = (DEFAULTS :: { [string]: ConfigValue })[key]
	if default == nil then
		-- Unknown key: nothing to resolve.
		return nil
	end
	local stored = self._plugin:GetSetting(KEY_PREFIX .. key)
	if stored == nil then
		return default
	end
	return stored :: ConfigValue
end

-- Validate, then persist. Returns true on success; false (with a reason) when
-- the value is rejected. Validation uses explicit nil checks so legitimate
-- `false`/`0` values are accepted.
function Config.set(self: Config, key: string, value: ConfigValue): (boolean, string?)
	if not isKnownKey(key) then
		return false, "unknown key: " .. tostring(key)
	end

	if key == "baseUrl" then
		if type(value) ~= "string" or value == "" then
			return false, "baseUrl must be a non-empty string"
		end
	elseif key == "proxyKey" then
		if type(value) ~= "string" then
			return false, "proxyKey must be a string"
		end
	elseif key == "sidecarUrl" then
		if type(value) ~= "string" or value == "" then
			return false, "sidecarUrl must be a non-empty string"
		end
	elseif key == "model" then
		if type(value) ~= "string" or not isAllowedModel(value) then
			return false, "model must be one of the allowed MODELS"
		end
	elseif key == "maxTokens" then
		if type(value) ~= "number" then
			return false, "maxTokens must be a number"
		end
		value = math.floor(clampNumber(value, 1, 16384, DEFAULTS.maxTokens))
	elseif key == "maxIterations" then
		if type(value) ~= "number" then
			return false, "maxIterations must be a number"
		end
		if value ~= value or value < 1 then
			return false, "maxIterations must be >= 1"
		end
		value = math.floor(value)
	elseif key == "confirmDestructive" then
		if type(value) ~= "boolean" then
			return false, "confirmDestructive must be a boolean"
		end
	elseif key == "retryMaxAttempts" then
		if type(value) ~= "number" then
			return false, "retryMaxAttempts must be a number"
		end
		if value ~= value or value < 1 then
			return false, "retryMaxAttempts must be >= 1"
		end
		value = math.floor(value)
	elseif key == "retryBaseDelay" then
		if type(value) ~= "number" then
			return false, "retryBaseDelay must be a number"
		end
		if value ~= value or value <= 0 then
			return false, "retryBaseDelay must be > 0"
		end
		-- Cross-field invariant: base delay must not exceed the (resolved) max
		-- delay, else backoff capping would invert/no-op.
		if value > self:getRetryMaxDelay() then
			return false, "retryBaseDelay must be <= retryMaxDelay"
		end
	elseif key == "retryMaxDelay" then
		if type(value) ~= "number" then
			return false, "retryMaxDelay must be a number"
		end
		if value ~= value or value <= 0 then
			return false, "retryMaxDelay must be > 0"
		end
		-- Cross-field invariant: max delay must not be below the (resolved) base
		-- delay, else backoff capping would invert/no-op.
		if value < self:getRetryBaseDelay() then
			return false, "retryMaxDelay must be >= retryBaseDelay"
		end
	elseif key == "contextWindow" then
		if type(value) ~= "number" or value ~= value or value < 1000 then
			return false, "contextWindow must be a number >= 1000"
		end
		value = math.floor(value)
	elseif key == "compactThreshold" then
		if type(value) ~= "number" or value ~= value or value <= 0 or value >= 1 then
			return false, "compactThreshold must be a number in (0, 1)"
		end
	elseif key == "keepRecentMessages" then
		if type(value) ~= "number" or value ~= value or value < 2 then
			return false, "keepRecentMessages must be a number >= 2"
		end
		value = math.floor(value)
	elseif key == "imagesKept" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "imagesKept must be a number >= 1"
		end
		value = math.floor(value)
	elseif key == "subagentModel" then
		if type(value) ~= "string" or not isAllowedModel(value) then
			return false, "subagentModel must be one of the allowed MODELS"
		end
	elseif key == "subagentMaxParallel" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "subagentMaxParallel must be >= 1"
		end
		value = math.floor(value)
	elseif key == "subagentMaxIterations" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "subagentMaxIterations must be >= 1"
		end
		value = math.floor(value)
	elseif key == "writerModel" then
		if type(value) ~= "string" or not isAllowedModel(value) then
			return false, "writerModel must be one of the allowed MODELS"
		end
	elseif key == "writerMaxParallel" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "writerMaxParallel must be >= 1"
		end
		value = math.floor(value)
	elseif key == "writerMaxIterations" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "writerMaxIterations must be >= 1"
		end
		value = math.floor(value)
	elseif key == "webSearchMaxUses" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "webSearchMaxUses must be >= 1"
		end
		value = math.floor(value)
	elseif key == "webFetchMaxUses" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "webFetchMaxUses must be >= 1"
		end
		value = math.floor(value)
	elseif key == "cameraRigDebug" then
		if type(value) ~= "boolean" then
			return false, "cameraRigDebug must be a boolean"
		end
	elseif key == "devBridge" then
		if type(value) ~= "boolean" then
			return false, "devBridge must be a boolean"
		end
	elseif key == "devBridgePollInterval" then
		if type(value) ~= "number" or value ~= value or value < 0.25 then
			return false, "devBridgePollInterval must be a number >= 0.25"
		end
	end

	self._plugin:SetSetting(KEY_PREFIX .. key, value)
	return true
end

-- Resolve every known key into a fresh table.
function Config.getAll(self: Config): { [string]: ConfigValue }
	local out: { [string]: ConfigValue } = {}
	for key in DEFAULTS :: { [string]: ConfigValue } do
		local resolved = self:get(key)
		if resolved ~= nil then
			out[key] = resolved
		end
	end
	return out
end

function Config.isConfigured(self: Config): boolean
	return self:getProxyKey() ~= "" and self:getBaseUrl() ~= ""
end

-- Convenience getters. PINNED names: later modules call these exactly.

function Config.getBaseUrl(self: Config): string
	return self:get("baseUrl") :: string
end

function Config.getProxyKey(self: Config): string
	return self:get("proxyKey") :: string
end

-- Vision sidecar getters (the `capture` tool reaches these through the dispatch context).

function Config.getSidecarUrl(self: Config): string
	return self:get("sidecarUrl") :: string
end

function Config.getModel(self: Config): string
	return self:get("model") :: string
end

function Config.getMaxTokens(self: Config): number
	return self:get("maxTokens") :: number
end

function Config.getMaxIterations(self: Config): number
	return self:get("maxIterations") :: number
end

function Config.getContextWindow(self: Config): number
	return self:get("contextWindow") :: number
end

function Config.getCompactThreshold(self: Config): number
	return self:get("compactThreshold") :: number
end

function Config.getKeepRecentMessages(self: Config): number
	return self:get("keepRecentMessages") :: number
end

function Config.getImagesKept(self: Config): number
	return self:get("imagesKept") :: number
end

function Config.getSubagentModel(self: Config): string
	return self:get("subagentModel") :: string
end

function Config.getSubagentMaxParallel(self: Config): number
	return self:get("subagentMaxParallel") :: number
end

function Config.getSubagentMaxIterations(self: Config): number
	return self:get("subagentMaxIterations") :: number
end

function Config.getWriterModel(self: Config): string
	return self:get("writerModel") :: string
end

function Config.getWriterMaxParallel(self: Config): number
	return self:get("writerMaxParallel") :: number
end

function Config.getWriterMaxIterations(self: Config): number
	return self:get("writerMaxIterations") :: number
end

function Config.getWebSearchMaxUses(self: Config): number
	return self:get("webSearchMaxUses") :: number
end

function Config.getWebFetchMaxUses(self: Config): number
	return self:get("webFetchMaxUses") :: number
end

-- Forward-looking getters for the M11 retry/confirm keys. Not spec-pinned, but
-- kept here so later modules read them through the single source of truth
-- instead of scattering stringly-typed self:get(...) casts at each call site.

function Config.getConfirmDestructive(self: Config): boolean
	return self:get("confirmDestructive") :: boolean
end

function Config.getCameraRigDebug(self: Config): boolean
	return self:get("cameraRigDebug") :: boolean
end

function Config.getDevBridge(self: Config): boolean
	return self:get("devBridge") :: boolean
end

function Config.getDevBridgePollInterval(self: Config): number
	return self:get("devBridgePollInterval") :: number
end

function Config.getRetryMaxAttempts(self: Config): number
	return self:get("retryMaxAttempts") :: number
end

function Config.getRetryBaseDelay(self: Config): number
	return self:get("retryBaseDelay") :: number
end

function Config.getRetryMaxDelay(self: Config): number
	return self:get("retryMaxDelay") :: number
end

return Config
