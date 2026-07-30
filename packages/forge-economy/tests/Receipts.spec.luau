--!strict
-- Specs for Receipts.
--
-- These model the ProcessReceipt contract, which is the part people get wrong: Roblox
-- redelivers a receipt until you return PurchaseGranted, so the grant-once record has to
-- survive a rejoin and a server restart.

local Receipts = require("../src/Receipts")

return function(t)
	t.test("an unseen receipt is not granted", function(expect)
		local r = Receipts.new()
		expect(r:IsGranted("p1", "receipt-1")).toBe(false)
		expect(r:Count("p1")).toBe(0)
	end)

	t.test("marking a grant records it", function(expect)
		local r = Receipts.new()
		expect(r:MarkGranted("p1", "receipt-1", { productId = 123 })).toBe(true)
		expect(r:IsGranted("p1", "receipt-1")).toBe(true)
		expect(r:Get("p1", "receipt-1").productId).toBe(123)
		expect(r:Count("p1")).toBe(1)
	end)

	-- IsGranted should have caught this; a second Mark means the caller has a bug.
	t.test("marking the same receipt twice returns false", function(expect)
		local r = Receipts.new()
		r:MarkGranted("p1", "receipt-1")
		expect(r:MarkGranted("p1", "receipt-1")).toBe(false)
		expect(r:Count("p1")).toBe(1)
	end)

	-- The whole contract, simulated: Roblox redelivers until PurchaseGranted.
	t.test("redelivery grants exactly once", function(expect)
		local r = Receipts.new()
		local granted = 0

		local function processReceipt(receiptId: string): boolean
			if r:IsGranted("p1", receiptId) then
				return true -- PurchaseGranted, without granting again
			end
			granted += 1
			r:MarkGranted("p1", receiptId, { productId = 7 })
			-- (a real caller saves the profile here and only returns true if it succeeded)
			return true
		end

		for _ = 1, 20 do
			expect(processReceipt("receipt-abc")).toBe(true)
		end
		expect(granted).toBe(1)
	end)

	-- Returning NotProcessedYet on a failed save is correct and safe: Roblox retries, and
	-- the IsGranted check makes the retry harmless.
	t.test("a failed save leaves the receipt ungranted so the retry can succeed", function(expect)
		local r = Receipts.new()
		local granted = 0
		local saveWorks = false

		local function processReceipt(receiptId: string): boolean
			if r:IsGranted("p1", receiptId) then
				return true
			end
			if not saveWorks then
				-- Do NOT mark: the grant is not durable, so it has not happened.
				return false -- NotProcessedYet
			end
			granted += 1
			r:MarkGranted("p1", receiptId)
			return true
		end

		expect(processReceipt("receipt-1")).toBe(false)
		expect(processReceipt("receipt-1")).toBe(false)
		expect(granted).toBe(0)
		saveWorks = true
		expect(processReceipt("receipt-1")).toBe(true)
		expect(processReceipt("receipt-1")).toBe(true)
		expect(granted).toBe(1)
	end)

	t.test("owners are independent", function(expect)
		local r = Receipts.new()
		r:MarkGranted("p1", "receipt-1")
		expect(r:IsGranted("p2", "receipt-1")).toBe(false)
	end)

	t.test("rejects an empty receipt id", function(expect)
		local r = Receipts.new()
		expect(r:MarkGranted("p1", "")).toBe(false)
		expect(r:Count("p1")).toBe(0)
	end)

	-- Eviction is a last-resort guard, not routine, so it is observable.
	t.test("eviction is bounded and reported loudly", function(expect)
		local evicted = {}
		local r = Receipts.new({
			limit = 2,
			onEvict = function(_owner, receiptId)
				table.insert(evicted, receiptId)
			end,
		})
		r:MarkGranted("p1", "r1")
		r:MarkGranted("p1", "r2")
		r:MarkGranted("p1", "r3")
		expect(r:Count("p1")).toBe(2)
		expect(evicted).toEqual({ "r1" })
		-- And the honest consequence: a very late redelivery of r1 would grant again.
		expect(r:IsGranted("p1", "r1")).toBe(false)
	end)

	-- This snapshot is the only thing standing between a redelivered receipt and a
	-- double-grant, so the round trip has to be exact.
	t.test("export/import survives a rejoin", function(expect)
		local r = Receipts.new()
		r:MarkGranted("p1", "receipt-1", { productId = 42 })
		r:MarkGranted("p1", "receipt-2", { productId = 43 })
		local snapshot = r:Export("p1")

		local fresh = Receipts.new()
		fresh:Import("p1", snapshot)
		expect(fresh:IsGranted("p1", "receipt-1")).toBe(true)
		expect(fresh:Get("p1", "receipt-2").productId).toBe(43)
		expect(fresh:Count("p1")).toBe(2)
		-- The point: a redelivery after the rejoin does not re-grant.
		expect(fresh:MarkGranted("p1", "receipt-1")).toBe(false)
	end)

	t.test("import of a malformed snapshot yields nothing granted", function(expect)
		local r = Receipts.new()
		r:Import("p1", nil)
		expect(r:Count("p1")).toBe(0)
		r:Import("p1", { order = "nope" } :: any)
		expect(r:Count("p1")).toBe(0)
	end)

	t.test("import tolerates missing record bodies", function(expect)
		local r = Receipts.new()
		r:Import("p1", { order = { "receipt-1" }, records = {} })
		expect(r:IsGranted("p1", "receipt-1")).toBe(true)
		expect(r:Get("p1", "receipt-1")).toEqual({})
	end)

	t.test("Get returns a copy", function(expect)
		local r = Receipts.new()
		r:MarkGranted("p1", "receipt-1", { productId = 1 })
		local record = r:Get("p1", "receipt-1")
		record.productId = 999
		expect(r:Get("p1", "receipt-1").productId).toBe(1)
	end)

	t.test("Forget drops an owner", function(expect)
		local r = Receipts.new()
		r:MarkGranted("p1", "receipt-1")
		r:Forget("p1")
		expect(r:IsGranted("p1", "receipt-1")).toBe(false)
	end)

	t.test("rejects a nonsense limit", function(expect)
		expect(function()
			Receipts.new({ limit = 0 })
		end).toThrow("limit must be at least 1")
	end)
end
