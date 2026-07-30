--!strict
-- forge-net: typed, schema-validated, rate-limited remotes for Roblox.
--
-- The value returned here is the package's ENTIRE public API.
--
-- The Router is realm-agnostic pure logic: it accepts a `validate` FUNCTION and a
-- `rateLimit` OBJECT rather than importing them, so it has zero dependencies and runs under
-- Lune. forge-guard's Validate.tuple and RateLimit satisfy both interfaces.
--
-- No require-time side effects: constructing a router touches nothing.

return require(script.Router)
