--!strict
-- Specs for Ledger.
--
-- The idempotency and dupe cases are the reason this package exists, so they get the most
-- attention. Economy bugs cannot be walked back.

local Ledger = require("../src/Ledger")

local function ledger(overrides)
	local options = { currencies = { "coins", "shards" } }
	for key, value in overrides or {} do
		options[key] = value
	end
	return Ledger.new(options)
end

local function txn(id: string, delta: number, currency: string?)
	return { id = id, owner = "p1", currency = currency or "coins", delta = delta }
end

return function(t)
	t.test("applies a grant and reports the new balance", function(expect)
		local l = ledger()
		local result = l:Apply(txn("t1", 50))
		expect(result.ok).toBe(true)
		expect(result.balance).toBe(50)
		expect(result.replay).toBe(false)
		expect(l:Balance("p1", "coins")).toBe(50)
	end)

	t.test("an unknown owner has a zero balance without being created", function(expect)
		local l = ledger()
		expect(l:Balance("nobody", "coins")).toBe(0)
		expect(l:Balances("nobody")).toEqual({})
	end)

	-- THE CORE PROPERTY.
	t.test(
		"applying the same transaction twice has the effect of applying it once",
		function(expect)
			local l = ledger()
			l:Apply(txn("t1", 50))
			local replay = l:Apply(txn("t1", 50))
			expect(replay.replay).toBe(true)
			expect(replay.balance).toBe(50)
			expect(l:Balance("p1", "coins")).toBe(50)
		end
	)

	-- A replay is a SUCCESS: the transaction happened, just earlier. Reporting it as a
	-- failure is how a retry loop becomes an infinite one.
	t.test("a replay reports ok, not failure", function(expect)
		local l = ledger()
		l:Apply(txn("t1", 50))
		expect(l:Apply(txn("t1", 50)).ok).toBe(true)
	end)

	t.test("a hundred retries of one transaction grant once", function(expect)
		local l = ledger()
		for _ = 1, 100 do
			l:Apply(txn("same-id", 10))
		end
		expect(l:Balance("p1", "coins")).toBe(10)
	end)

	-- Same amount, different ids: two genuine transactions, not a replay.
	t.test("distinct ids are distinct transactions", function(expect)
		local l = ledger()
		l:Apply(txn("t1", 10))
		l:Apply(txn("t2", 10))
		expect(l:Balance("p1", "coins")).toBe(20)
	end)

	t.test("spends subtract and are also idempotent", function(expect)
		local l = ledger()
		l:Apply(txn("grant", 100))
		expect(l:Apply(txn("spend", -30)).balance).toBe(70)
		expect(l:Apply(txn("spend", -30)).replay).toBe(true)
		expect(l:Balance("p1", "coins")).toBe(70)
	end)

	t.test("refuses to overdraw by default", function(expect)
		local l = ledger()
		l:Apply(txn("grant", 10))
		local result = l:Apply(txn("spend", -50))
		expect(result.ok).toBe(false)
		expect(result.reason).toBe("insufficient funds")
		-- Balance untouched by a rejected transaction.
		expect(l:Balance("p1", "coins")).toBe(10)
	end)

	t.test(
		"a rejected transaction is not recorded, so a later valid one with that id works",
		function(expect)
			local l = ledger()
			l:Apply(txn("t1", -50)) -- rejected: insufficient funds
			l:Apply(txn("grant", 100))
			expect(l:Apply(txn("t1", -50)).ok).toBe(true)
			expect(l:Balance("p1", "coins")).toBe(50)
		end
	)

	t.test("allowCredit permits a negative balance when asked", function(expect)
		local l = ledger({ allowCredit = true })
		expect(l:Apply(txn("t1", -50)).balance).toBe(-50)
	end)

	t.test("currencies are independent", function(expect)
		local l = ledger()
		l:Apply(txn("t1", 10, "coins"))
		l:Apply(txn("t2", 5, "shards"))
		expect(l:Balance("p1", "coins")).toBe(10)
		expect(l:Balance("p1", "shards")).toBe(5)
		expect(l:Balances("p1")).toEqual({ coins = 10, shards = 5 })
	end)

	-- A typo should not silently mint a parallel wallet.
	t.test("an unknown currency is rejected, not created", function(expect)
		local l = ledger()
		local result = l:Apply(txn("t1", 10, "coin"))
		expect(result.ok).toBe(false)
		expect(result.reason).toContain("unknown currency")
		expect(l:Balances("p1")).toEqual({})
	end)

	t.test("owners are independent", function(expect)
		local l = ledger()
		l:Apply({ id = "t1", owner = "p1", currency = "coins", delta = 10 })
		l:Apply({ id = "t1", owner = "p2", currency = "coins", delta = 99 })
		-- Same id, different owner: not a replay.
		expect(l:Balance("p1", "coins")).toBe(10)
		expect(l:Balance("p2", "coins")).toBe(99)
	end)

	-- Hostile and malformed input. forge-guard should catch these at the boundary, but a
	-- ledger is the last thing standing between a bad number and permanent damage.
	t.test("rejects NaN, which would otherwise poison the balance forever", function(expect)
		local l = ledger()
		local result = l:Apply(txn("t1", 0 / 0))
		expect(result.ok).toBe(false)
		expect(result.reason).toBe("delta is NaN")
		expect(l:Balance("p1", "coins")).toBe(0)
	end)

	t.test("rejects infinities, fractions and non-numbers", function(expect)
		local l = ledger()
		expect(l:Apply(txn("a", math.huge)).reason).toBe("delta is infinite")
		expect(l:Apply(txn("b", -math.huge)).reason).toBe("delta is infinite")
		expect(l:Apply(txn("c", 1.5)).reason).toBe("delta must be an integer")
		expect(l:Apply(txn("d", "10" :: any)).reason).toBe("delta must be a number")
		expect(l:Balance("p1", "coins")).toBe(0)
	end)

	t.test("rejects a missing or empty transaction id", function(expect)
		local l = ledger()
		expect(l:Apply({ id = "", owner = "p1", currency = "coins", delta = 1 }).ok).toBe(false)
		expect(l:Apply({ id = nil :: any, owner = "p1", currency = "coins", delta = 1 }).ok).toBe(
			false
		)
	end)

	t.test("enforces a balance ceiling", function(expect)
		local l = ledger({ maxBalance = 100 })
		expect(l:Apply(txn("t1", 100)).ok).toBe(true)
		local result = l:Apply(txn("t2", 1))
		expect(result.ok).toBe(false)
		expect(result.reason).toBe("balance ceiling exceeded")
		expect(l:Balance("p1", "coins")).toBe(100)
	end)

	t.test("bounds retained ids, evicting oldest first", function(expect)
		local l = ledger({ historyLimit = 3 })
		for index = 1, 5 do
			l:Apply(txn(`t{index}`, 1))
		end
		expect(l:Balance("p1", "coins")).toBe(5)
		expect(l:History("p1")).toEqual({ "t3", "t4", "t5" })
		expect(l:HasApplied("p1", "t5")).toBe(true)
		-- The honest limitation, asserted so nobody is surprised by it: beyond the window
		-- a replay is no longer detectable.
		expect(l:HasApplied("p1", "t1")).toBe(false)
		l:Apply(txn("t1", 1))
		expect(l:Balance("p1", "coins")).toBe(6)
	end)

	-- Persistence. Saving balances WITHOUT the applied ids means the first retry after a
	-- rejoin is a dupe, so the round trip is worth asserting hard.
	t.test("export/import round-trips balances and idempotency together", function(expect)
		local l = ledger()
		l:Apply(txn("t1", 40))
		l:Apply(txn("t2", 5, "shards"))
		local snapshot = l:Export("p1")

		local restored = ledger()
		restored:Import("p1", snapshot)
		expect(restored:Balance("p1", "coins")).toBe(40)
		expect(restored:Balance("p1", "shards")).toBe(5)
		-- The whole point: a retry that survives a rejoin still does not double-apply.
		expect(restored:Apply(txn("t1", 40)).replay).toBe(true)
		expect(restored:Balance("p1", "coins")).toBe(40)
	end)

	t.test("import of a nil or malformed snapshot yields an empty account", function(expect)
		local l = ledger()
		l:Import("p1", nil)
		expect(l:Balances("p1")).toEqual({})
		l:Import("p1", "garbage" :: any)
		expect(l:Balances("p1")).toEqual({})
	end)

	-- Stored data outlives every assumption in the code that wrote it.
	t.test("import drops currencies the ledger no longer knows about", function(expect)
		local l = ledger()
		l:Import("p1", { balances = { coins = 10, gems = 999 }, applied = {} })
		expect(l:Balance("p1", "coins")).toBe(10)
		expect(l:Balances("p1")).toEqual({ coins = 10 })
	end)

	t.test("import rejects non-integer and NaN balances from stored data", function(expect)
		local l = ledger()
		l:Import("p1", { balances = { coins = 1.5, shards = 0 / 0 }, applied = {} })
		expect(l:Balances("p1")).toEqual({})
	end)

	t.test("Export and Balances return copies", function(expect)
		local l = ledger()
		l:Apply(txn("t1", 10))
		local snapshot = l:Export("p1")
		snapshot.balances.coins = 9999
		l:Balances("p1").coins = 8888
		expect(l:Balance("p1", "coins")).toBe(10)
	end)

	t.test("Forget drops an owner", function(expect)
		local l = ledger()
		l:Apply(txn("t1", 10))
		l:Forget("p1")
		expect(l:Balance("p1", "coins")).toBe(0)
		expect(l:HasApplied("p1", "t1")).toBe(false)
	end)

	t.test("rejects a ledger with no currencies", function(expect)
		expect(function()
			Ledger.new({ currencies = {} })
		end).toThrow("at least one currency")
	end)
end
