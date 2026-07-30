--!strict
-- forge-signal: Signal, promise and cleanup primitives for Luau
--
-- The value returned here is the package's ENTIRE public API - nothing else in
-- this folder is reachable by a consumer. Keep the surface small, and keep
-- require-time free of side effects (a consumer may require this on both
-- realms; initialise through an explicit :Init()/:Start() instead).
--
-- Keep this file a thin aggregator: logic belongs in siblings so it stays
-- testable under Lune, which has no `script`.

return require(script.ForgeSignal)
