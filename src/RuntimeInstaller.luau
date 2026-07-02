--!strict
-- RuntimeInstaller: installs/updates the GIT-VERSIONED in-game runtime library
-- (repo runtime/*.luau, served by the sidecar at GET /runtime) as
-- ReplicatedStorage.StudioAgentRuntime — a Folder of ModuleScripts + a Version attribute.
-- The bind_* tools call ensureInstalled() and then write THIN LAUNCHERS that require() these
-- modules, replacing the old stamped one-copy-per-instance script islands: an improvement to a
-- runtime module now upgrades every future build (and every existing launcher on re-install),
-- which is the hardest-compounding store in the game-factory design. Idempotent
-- (skip-if-same-version); fail-open (sidecar down -> callers fall back to stamping the full
-- legacy source, so nothing hard-depends on the sidecar).

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeInstaller = {}

local FOLDER_NAME = "StudioAgentRuntime"

-- ---- pure (spec-tested) ----

-- Install when nothing is installed, or the installed version is OLDER. Same-or-newer -> keep
-- (a place saved with a newer library than this sidecar serves must not be downgraded).
function RuntimeInstaller.needsInstall(current: number?, incoming: number): boolean
	if type(current) ~= "number" or current ~= current then
		return true
	end
	return current < incoming
end

-- The thin launcher a bind_* tool writes instead of a stamped full source. `moduleName` is the
-- library module; the launcher's own Name (e.g. "ItemBehaviorRuntime") is chosen by the caller so
-- existing PlayBridge verbs/specs keep working. ASCII-only.
function RuntimeInstaller.launcherSource(moduleName: string): string
	return "-- Launcher (auto-generated): logic lives in ReplicatedStorage.StudioAgentRuntime."
		.. moduleName
		.. " (git-versioned library).\n"
		.. 'local rt = game:GetService("ReplicatedStorage"):WaitForChild("StudioAgentRuntime", 10)\n'
		.. 'local mod = rt and rt:FindFirstChild("'
		.. moduleName
		.. '")\n'
		.. "if mod then\n"
		.. "\trequire(mod).attach(script.Parent)\n"
		.. "else\n"
		.. '\twarn("[StudioAgent] runtime module missing: '
		.. moduleName
		.. '")\n'
		.. "end\n"
end

-- ---- impure ----

-- Fetch {version, modules} from the sidecar. Total: (payload, nil) or (nil, err).
local function fetchRuntime(config: any): (any?, string?)
	if config == nil then
		return nil, "no config"
	end
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = config:getSidecarUrl() .. "/runtime",
			Method = "GET",
		})
	end)
	if not ok then
		return nil, "sidecar unreachable (" .. tostring(res) .. ")"
	end
	local r = res :: any
	if not r.Success then
		return nil, "sidecar HTTP " .. tostring(r.StatusCode)
	end
	local okDec, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if
		not okDec
		or type(payload) ~= "table"
		or type((payload :: any).version) ~= "number"
		or type((payload :: any).modules) ~= "table"
	then
		return nil, "bad /runtime response"
	end
	return payload, nil
end

local function installedFolder(): Folder?
	local f = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if f ~= nil and f:IsA("Folder") then
		return f
	end
	return nil
end

-- Ensure the library is present + current. Returns (ok, note). ok=true means launchers can
-- rely on the library (present, even if a fetch failed); ok=false means callers should fall
-- back to stamping the legacy full source.
function RuntimeInstaller.ensureInstalled(config: any): (boolean, string)
	local existing = installedFolder()
	local current = if existing ~= nil then existing:GetAttribute("Version") else nil

	local payload, err = fetchRuntime(config)
	if payload == nil then
		if existing ~= nil then
			return true,
				"runtime v" .. tostring(current) .. " already installed (sidecar unavailable: " .. tostring(
					err
				) .. ")"
		end
		return false, "runtime library unavailable: " .. tostring(err)
	end

	local incoming = (payload :: any).version :: number
	if existing ~= nil and not RuntimeInstaller.needsInstall(tonumber(current), incoming) then
		return true, "runtime v" .. tostring(current) .. " current"
	end

	local folder = existing
	if folder == nil then
		local f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = ReplicatedStorage
		folder = f
	end
	local theFolder = folder :: Folder
	local written = 0
	for name, source in (payload :: any).modules :: { [string]: string } do
		if type(name) == "string" and type(source) == "string" then
			local old = theFolder:FindFirstChild(name)
			if old ~= nil then
				old:Destroy()
			end
			local m = Instance.new("ModuleScript")
			m.Name = name
			m.Source = source
			m.Parent = theFolder
			written += 1
		end
	end
	theFolder:SetAttribute("Version", incoming)
	return true,
		"installed StudioAgentRuntime v"
			.. tostring(incoming)
			.. " ("
			.. tostring(written)
			.. " modules)"
end

return RuntimeInstaller
