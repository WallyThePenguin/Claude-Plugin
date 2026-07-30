--!strict
-- Specs for forge-signal. Run with: lune run scripts/test.luau forge-signal

local ForgeSignal = require("../src/ForgeSignal")

return function(t)
	t.test("Forge Signal loads", function(expect)
		expect(type(ForgeSignal)).toBe("table")
	end)
end
