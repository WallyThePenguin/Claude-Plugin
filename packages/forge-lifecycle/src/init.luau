--!strict
-- forge-lifecycle: service registry with dependency-ordered Init and Start phases.
--
-- The value returned here is the package's ENTIRE public API.
--
-- Realm-agnostic: run one registry per realm (one on the server, one on the client).
-- No require-time side effects - constructing a registry does nothing until you Init it.
--
-- Thin aggregator: all the logic is in Registry.luau, which is pure Luau and fully
-- specced under Lune.

return require(script.Registry)
