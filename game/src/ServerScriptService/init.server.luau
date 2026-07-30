--!strict
-- Forge Arena -- server entry point.
--
-- The whole server is composition: build the services, hand them to forge-lifecycle, and
-- let it resolve the order. Nothing here holds game logic, and nothing here decides a load
-- order by hand -- a service declares what it Requires and the registry works it out.
--
-- What that buys: adding a service never means editing a list, and a missing or circular
-- dependency fails LOUDLY at boot with a named path instead of silently at 3am under load.
--
-- Replaces the old ForgeRoundLoop `while true` skeleton, which could not be interrupted,
-- inspected, or tested.

local ServerScriptService = game:GetService("ServerScriptService")

local ServerPackages = ServerScriptService:WaitForChild("Packages")
local Lifecycle = require(ServerPackages["forge-lifecycle"])

local Services = script:WaitForChild("Services")

local registry = Lifecycle.new()
registry:Add(require(Services.CombatService))
registry:Add(require(Services.RewardService))
registry:Add(require(Services.WaveService))

-- Log the resolved boot order. It is deterministic (insertion order breaks ties), so this
-- line is comparable run to run -- which makes it useful in a bug report.
print(`[forge] boot order: {table.concat(registry:Order(), ", ")}`)

registry:Init()
registry:Start()

print("[forge] server ready")
