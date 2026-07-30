--!strict
-- forge-testkit: Roblox API fakes so Luau packages can be unit-tested under Lune.
--
-- The value returned here is the package's ENTIRE public API.
--
-- DEV DEPENDENCY. Nothing in shipped code should require this. It is published so other
-- projects can test against the same fakes, and because `.forestignore` keeps tests out of
-- the archive, a consumer's specs are the only thing that ever loads it.
--
-- Two notes on using these from a spec in THIS workspace:
--   * Lune requires are file paths, so a spec in another package reaches them directly:
--     require("../../forge-testkit/src/FakeClock"). That is a dev-time file reference, not
--     a Forest dependency - which is why no package here declares testkit in forest.json.
--   * Every fake is pure Luau with no Roblox API, so it loads anywhere.

return {
	-- A clock you drive by hand. Turns "after 30 seconds" into an instant assertion.
	Clock = require(script.FakeClock),
	Signal = require(script.FakeSignal),
	-- An in-memory DataStore that can be made to fail on demand.
	DataStore = require(script.FakeDataStore),
	Players = require(script.FakePlayers),
	-- RemoteEvent / RemoteFunction stand-ins. FireServer takes the sender explicitly,
	-- so "player B claims to act as player A" is expressible.
	Remote = require(script.FakeRemote),
}
