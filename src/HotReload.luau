--!strict
-- HotReload: the dev-bridge hot-reload engine. Clones the plugin's module tree, writes fresh source onto
-- the clones, and re-requires Main so a code change applies with NO Studio restart. PURE resolvePath +
-- newLifecycle are unit-tested in HotReloadSpec; the impure reload/startSupervisor (clone + require +
-- swap + the poll loop) are added in a later task and live-verified. This module is the STABLE core (the
-- bootstrap requires it), so changes to HotReload itself still need a restart. See
-- docs/superpowers/specs/2026-06-26-dev-bridge-hot-reload-design.md.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local HotReload = {}

export type Lifecycle = {
	cancelled: boolean,
	connections: { RBXScriptConnection },
	add: (self: any, conn: RBXScriptConnection) -> (),
	cancel: (self: any) -> (),
}

-- A per-generation lifecycle: tracks event connections so a reload can disconnect them, and a `cancelled`
-- flag the dev-bridge loop checks each tick to exit. PURE (no DataModel reads).
function HotReload.newLifecycle(): Lifecycle
	local lc = { cancelled = false, connections = {} :: { RBXScriptConnection } }
	function lc.add(self, conn)
		table.insert(self.connections, conn)
	end
	function lc.cancel(self)
		self.cancelled = true
		for _, conn in self.connections do
			pcall(function()
				conn:Disconnect()
			end)
		end
		self.connections = {}
	end
	return lc :: any
end

-- Map a Rojo relative source path to (parentInstance, childName) within `container` so the caller can
-- find-or-create the ModuleScript and set its Source. "X/init.luau" targets the folder-module X itself;
-- "Tools/Animate.luau" targets Animate under Tools; "AnimationClip.luau" targets AnimationClip at the
-- root. Missing intermediate folders are created (as Folder). Returns (nil, nil) for the bootstrap
-- ("init.server.luau"), a bare root "init.luau", or a non-.luau path. PURE-ish (deterministic; only
-- creates intermediate Folders). Unit-tested.
function HotReload.resolvePath(container: Instance, relpath: string): (Instance?, string?)
	if relpath == "init.server.luau" then
		return nil, nil
	end
	local name = string.gsub(relpath, "%.luau$", "")
	if name == relpath then
		return nil, nil -- not a .luau file
	end
	local segs = string.split(name, "/")
	local targetName: string
	local parentSegs: { string } = {}
	if segs[#segs] == "init" then
		if #segs < 2 then
			return nil, nil -- a bare root init.luau has no folder-module to target
		end
		targetName = segs[#segs - 1]
		for i = 1, #segs - 2 do
			table.insert(parentSegs, segs[i])
		end
	else
		targetName = segs[#segs]
		for i = 1, #segs - 1 do
			table.insert(parentSegs, segs[i])
		end
	end
	local parent: Instance = container
	for _, seg in parentSegs do
		local child = parent:FindFirstChild(seg)
		if child == nil then
			local f = Instance.new("Folder")
			f.Name = seg
			f.Parent = parent
			child = f
		end
		parent = child
	end
	return parent, targetName
end

-- ---- impure (clone + require + swap; the poll loop) — live-verified ----

local function httpGetJson(url: string): (any?, string?)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if not ok then
		return nil, tostring(res)
	end
	local r = res :: any
	if not r.Success then
		return nil, "HTTP " .. tostring(r.StatusCode)
	end
	local okDecode, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not okDecode then
		return nil, "bad json"
	end
	return payload, nil
end

local function httpPostJson(url: string, body: any)
	pcall(function()
		HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
		})
	end)
end

-- Sort source entries so a folder's init.luau is applied BEFORE its leaf siblings — a brand-new
-- folder-module then becomes a ModuleScript before a leaf would create it as a Folder.
local function sortedEntries(sources: { [string]: string }): { { path: string, source: string } }
	local entries: { { path: string, source: string } } = {}
	for path, source in sources do
		table.insert(entries, { path = path, source = source })
	end
	table.sort(entries, function(a, b)
		local ai = if string.find(a.path, "init%.luau$") ~= nil then 0 else 1
		local bi = if string.find(b.path, "init%.luau$") ~= nil then 0 else 1
		if ai ~= bi then
			return ai < bi
		end
		return a.path < b.path
	end)
	return entries
end

-- Clone the bootstrap's module tree into a fresh container, write the synced source onto the clones
-- (creating instances for new paths; skipping the bootstrap), require the fresh Main, and — on success —
-- cancel the old generation and run the new one. On ANY failure the new clone is discarded and the
-- caller's old generation is left intact; the stable supervisor (which calls this) survives regardless,
-- so a fixed reload always recovers. Returns (ok, err).
function HotReload.reload(
	pluginScript: Instance,
	runtime: any,
	ctx: any,
	sources: { [string]: string }
): (boolean, string?)
	local container = Instance.new("Folder")
	container.Name = "StudioAgentReload"
	for _, child in pluginScript:GetChildren() do
		child:Clone().Parent = container
	end
	for _, e in sortedEntries(sources) do
		local parent, childName = HotReload.resolvePath(container, e.path)
		if parent ~= nil and childName ~= nil then
			local target = parent:FindFirstChild(childName)
			if target == nil then
				local ms = Instance.new("ModuleScript")
				ms.Name = childName
				ms.Parent = parent
				target = ms
			end
			-- The clone already carries the current source; only write when it actually changed. This
			-- also skips a needless large-source write for unchanged generated files (e.g. BuiltinRubrics).
			local current: string? = nil
			pcall(function()
				current = (target :: any).Source
			end)
			if current ~= e.source then
				-- Direct .Source caps at 200000 chars; fall back to ScriptEditorService for larger sources
				-- (e.g. the ~426KB generated BuiltinRubrics). UpdateSourceAsync works on the unparented clone.
				local okWrite = pcall(function()
					(target :: any).Source = e.source
				end)
				if not okWrite then
					okWrite = pcall(function()
						ScriptEditorService:UpdateSourceAsync(target :: any, function()
							return e.source
						end)
					end)
				end
				if not okWrite then
					warn("[StudioAgent] hot-reload: failed to write source for " .. e.path)
				end
			end
		end
	end

	local mainModule = container:FindFirstChild("Main")
	if mainModule == nil or not mainModule:IsA("ModuleScript") then
		container:Destroy()
		return false, "reload: no Main ModuleScript in the synced source"
	end
	local okRequire, fresh = pcall(require, mainModule :: ModuleScript)
	if not okRequire then
		container:Destroy()
		return false, "reload: Main require error — " .. tostring(fresh)
	end
	if type(fresh) ~= "table" or type((fresh :: any).run) ~= "function" then
		container:Destroy()
		return false, "reload: fresh Main has no run()"
	end

	-- Tear down the old generation, then run the new one. (require already caught load-time errors; if
	-- Main.run itself throws, the old loop is down but the stable supervisor recovers on the next reload.)
	if runtime.lifecycle ~= nil then
		pcall(function()
			runtime.lifecycle:cancel()
		end)
	end
	local okRun, result = pcall(function()
		return (fresh :: any).run(ctx)
	end)
	if not okRun then
		container:Destroy()
		return false, "reload: Main.run error — " .. tostring(result)
	end

	local oldContainer = runtime.container
	runtime.container = container
	runtime.lifecycle = result
	if oldContainer ~= nil then
		pcall(function()
			oldContainer:Destroy()
		end)
	end
	return true, nil
end

-- The STABLE supervisor loop (lives in the bootstrap generation, never cancelled). Polls /reload/pending;
-- on a request, reloads and posts the outcome. EDIT-only. `config` is a bootstrap-owned Config (stable),
-- not a generation's deps. `pluginScript` is the bootstrap Script (its children are the module tree).
function HotReload.startSupervisor(pluginScript: Instance, config: any, runtime: any, ctx: any)
	if not RunService:IsEdit() then
		return
	end
	if not config:getDevBridge() then
		return
	end
	task.spawn(function()
		local base = config:getSidecarUrl()
		print("[StudioAgent] hot-reload supervisor active (sidecar " .. base .. ")")
		while true do
			local pending = httpGetJson(base .. "/reload/pending")
			if
				type(pending) == "table"
				and (pending :: any).requested == true
				and type((pending :: any).sources) == "table"
			then
				local p = pending :: any
				local ok, err = HotReload.reload(pluginScript, runtime, ctx, p.sources)
				httpPostJson(base .. "/reload/result", { id = p.id, ok = ok, error = err })
				print(
					"[StudioAgent] hot-reload "
						.. (if ok then "OK" else "FAILED — " .. tostring(err))
				)
			end
			task.wait(config:getDevBridgePollInterval())
		end
	end)
end

return HotReload
