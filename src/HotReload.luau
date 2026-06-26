--!strict
-- HotReload: the dev-bridge hot-reload engine. Clones the plugin's module tree, writes fresh source onto
-- the clones, and re-requires Main so a code change applies with NO Studio restart. PURE resolvePath +
-- newLifecycle are unit-tested in HotReloadSpec; the impure reload/startSupervisor (clone + require +
-- swap + the poll loop) are added in a later task and live-verified. This module is the STABLE core (the
-- bootstrap requires it), so changes to HotReload itself still need a restart. See
-- docs/superpowers/specs/2026-06-26-dev-bridge-hot-reload-design.md.

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

return HotReload
