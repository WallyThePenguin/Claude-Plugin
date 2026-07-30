--!strict
-- forge-economy: idempotent currency and purchase transactions.
--
-- The value returned here is the package's ENTIRE public API.
--
-- SERVER REALM ONLY. Mount under ServerScriptService via Forest's two-manifest pattern. An
-- economy the client can read is an economy the client can plan against; one it can reach
-- is one it can rob.
--
-- Built around a single property: applying the same transaction twice has the same effect
-- as applying it once. Retries are routine -- a DataStore write fails and retries, a player
-- rejoins mid-purchase, Roblox redelivers a receipt -- and every one of those replays a
-- transaction. A ledger that adds the amount again on each is a dupe generator.
--
-- Both modules are pure, synchronous and non-yielding on purpose: the classic dupe is a
-- read-modify-write split across a yield, and you cannot write that bug against an API with
-- nowhere to yield. Persistence is the caller's (lapis, via Export/Import).

return {
	-- Soft-currency transactions with a bounded idempotency window.
	Ledger = require(script.Ledger),
	-- Grant-once records for real-money purchases. Separate store, much longer retention,
	-- and loud eviction -- a lost receipt record is a double-grant of something the player
	-- actually paid for.
	Receipts = require(script.Receipts),
}
