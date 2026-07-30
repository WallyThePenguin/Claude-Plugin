--!strict
-- Receipts: grant-once records for real-money purchases.
--
-- SEPARATE FROM THE LEDGER ON PURPOSE. Soft-currency idempotency can afford a bounded
-- window -- a retry that arrives after eviction is a rounding error in a made-up currency.
-- A Robux receipt cannot. Roblox RE-DELIVERS a receipt to ProcessReceipt until you return
-- PurchaseGranted, across server restarts and rejoins, and a receipt record that ages out
-- becomes a double-grant of something the player paid actual money for. So receipts get
-- their own store, their own (much larger) retention, and eviction that is loud.
--
-- ============================================================================
-- THE ORDERING RULE. Get this wrong and you will double-grant or lose purchases.
-- ============================================================================
--
--   1. Already granted?  -> return PurchaseGranted immediately. Do NOT grant again.
--   2. Not granted yet   -> apply the grant, mark it, and PERSIST THE PROFILE.
--   3. Only after the save SUCCEEDS -> return PurchaseGranted.
--
-- Returning PurchaseGranted before the save lands is the classic mistake: Roblox considers
-- the purchase settled and stops retrying, the server dies before the write, and the player
-- has paid for nothing. Returning NotProcessedYet on a failed save is correct and safe --
-- Roblox will simply try again, and step 1 makes that harmless.
--
-- Pure Luau: no services, no yielding. The caller owns the save, because the caller is the
-- only one who can know whether it succeeded.

export type Record = {
	productId: number?,
	-- Whatever the caller wants in the audit trail: amount, currency spent, timestamp.
	meta: { [string]: any }?,
}

export type Options = {
	-- Receipts retained per owner. Deliberately large: this is not a cache, it is a
	-- correctness record. Eviction is a last-resort guard against an unbounded profile,
	-- not a normal occurrence -- see onEvict.
	limit: number?,
	-- Called when a receipt record is evicted to stay under the limit. This should be
	-- LOUD in production: it means a player has bought so many products that the oldest
	-- record is gone, and a very late redelivery of that receipt would double-grant.
	onEvict: ((owner: unknown, receiptId: string) -> ())?,
}

local DEFAULT_LIMIT = 2048

local Receipts = {}
Receipts.__index = Receipts

export type Receipts = {
	IsGranted: (self: Receipts, owner: unknown, receiptId: string) -> boolean,
	MarkGranted: (self: Receipts, owner: unknown, receiptId: string, record: Record?) -> boolean,
	Get: (self: Receipts, owner: unknown, receiptId: string) -> Record?,
	Count: (self: Receipts, owner: unknown) -> number,
	Export: (self: Receipts, owner: unknown) -> any,
	Import: (self: Receipts, owner: unknown, snapshot: any) -> (),
	Forget: (self: Receipts, owner: unknown) -> (),
}

function Receipts.new(options: Options?): Receipts
	local opts: Options = options or {}
	local limit = opts.limit or DEFAULT_LIMIT
	assert(limit >= 1, "limit must be at least 1")

	return (
		setmetatable({
			_limit = limit,
			_onEvict = opts.onEvict,
			-- owner -> { records = {id -> Record}, order = {id} }
			_owners = {} :: { [unknown]: any },
		}, Receipts) :: any
	) :: Receipts
end

function Receipts._owner(self: any, owner: unknown)
	local entry = self._owners[owner]
	if entry == nil then
		entry = { records = {}, order = {} }
		self._owners[owner] = entry
	end
	return entry
end

--[[
	Step 1 of the ordering rule. Check this FIRST, before doing anything that grants value.
]]
function Receipts.IsGranted(self: Receipts, owner: unknown, receiptId: string): boolean
	local entry = (self :: any)._owners[owner]
	return entry ~= nil and entry.records[receiptId] ~= nil
end

--[[
	Step 2. Record the grant. Returns false if it was already recorded, which means the
	caller granted twice and has a bug -- IsGranted should have caught it.

	This only updates memory. The caller must still persist the profile and must not report
	PurchaseGranted until that save succeeds.
]]
function Receipts.MarkGranted(
	self: Receipts,
	owner: unknown,
	receiptId: string,
	record: Record?
): boolean
	local this = self :: any
	if typeof(receiptId) ~= "string" or receiptId == "" then
		return false
	end

	local entry = Receipts._owner(this, owner)
	if entry.records[receiptId] ~= nil then
		return false
	end

	entry.records[receiptId] = record or {}
	table.insert(entry.order, receiptId)

	while #entry.order > this._limit do
		local evicted = table.remove(entry.order, 1) :: string
		entry.records[evicted] = nil
		if this._onEvict then
			this._onEvict(owner, evicted)
		end
	end

	return true
end

function Receipts.Get(self: Receipts, owner: unknown, receiptId: string): Record?
	local entry = (self :: any)._owners[owner]
	if entry == nil then
		return nil
	end
	local record = entry.records[receiptId]
	return if record then table.clone(record) else nil
end

function Receipts.Count(self: Receipts, owner: unknown): number
	local entry = (self :: any)._owners[owner]
	return if entry then #entry.order else 0
end

--[[
	Snapshot for persistence. This MUST be saved with the profile -- it is the only thing
	standing between a redelivered receipt and a double-grant.
]]
function Receipts.Export(self: Receipts, owner: unknown): any
	local entry = (self :: any)._owners[owner]
	if entry == nil then
		return { order = {}, records = {} }
	end
	return {
		order = table.clone(entry.order),
		records = table.clone(entry.records),
	}
end

function Receipts.Import(self: Receipts, owner: unknown, snapshot: any): ()
	local this = self :: any
	local entry = Receipts._owner(this, owner)
	table.clear(entry.records)
	table.clear(entry.order)

	if typeof(snapshot) ~= "table" or typeof(snapshot.order) ~= "table" then
		return
	end

	local records = if typeof(snapshot.records) == "table" then snapshot.records else {}
	for _, id in snapshot.order do
		if typeof(id) == "string" and entry.records[id] == nil then
			local record = records[id]
			entry.records[id] = if typeof(record) == "table" then record else {}
			table.insert(entry.order, id)
		end
	end
end

function Receipts.Forget(self: Receipts, owner: unknown): ()
	(self :: any)._owners[owner] = nil
end

return Receipts
