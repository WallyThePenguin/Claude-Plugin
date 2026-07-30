--!strict
-- Ledger: idempotent currency transactions.
--
-- Economy bugs are the ones you cannot walk back. A combat bug annoys players for an
-- evening; a dupe permanently devalues every currency in the game and there is no honest
-- rollback once the duplicated goods have been spent and traded. So this module is built
-- around one property, and everything else is subordinate to it:
--
--   APPLYING THE SAME TRANSACTION TWICE HAS THE SAME EFFECT AS APPLYING IT ONCE.
--
-- That matters because retries are not exceptional, they are routine: a DataStore write
-- fails and is retried, a player rejoins mid-purchase, Roblox's ProcessReceipt re-delivers
-- a receipt until you return PurchaseGranted. Every one of those replays a transaction. A
-- ledger that adds the amount again on each is a dupe generator with extra steps.
--
-- THE OTHER HALF IS ORDERING, and it lives in the caller, not here. `Apply` is synchronous
-- and never yields, which is deliberate: the classic dupe is a read-modify-write split
-- across a yield, where two interleaved requests both read the pre-write balance. You
-- cannot write that bug against this API, because there is nowhere to yield.
--
-- Pure Luau, no services, no clock of its own -- so every guarantee above is under test.

export type Currency = string

export type Transaction = {
	-- SERVER-GENERATED, globally unique, and stable across retries of the SAME logical
	-- transaction. Never let a client supply this: a client that picks the id decides
	-- whether their purchase is a replay, which hands them the dupe directly.
	id: string,
	owner: unknown,
	currency: Currency,
	-- Signed integer. Positive grants, negative spends.
	delta: number,
	-- Free-form category for auditing: "reward", "purchase", "refund", "receipt".
	kind: string?,
	-- Anything you want in the audit trail.
	meta: { [string]: any }?,
}

export type Result = {
	ok: boolean,
	-- Balance after the transaction (or the current balance on rejection).
	balance: number,
	-- True when this id had already been applied and nothing changed.
	replay: boolean,
	reason: string?,
}

export type Options = {
	-- Currencies this ledger recognises. An unknown currency is REJECTED rather than
	-- created on demand: a typo should not silently mint a parallel wallet.
	currencies: { Currency },
	-- Per-currency ceiling. Defaults to 2^53 - past that, integer arithmetic in a
	-- 64-bit float stops being exact and a balance is no longer the number it claims.
	maxBalance: number?,
	-- Allow a balance to go negative. Off by default; almost nothing should.
	allowCredit: boolean?,
	-- How many applied transaction ids to retain per owner. See the note on retention
	-- below -- this bound is a real trade, not a tuning detail.
	historyLimit: number?,
}

local MAX_SAFE_INTEGER = 9007199254740992
local DEFAULT_HISTORY_LIMIT = 256

local Ledger = {}
Ledger.__index = Ledger

export type Ledger = {
	Apply: (self: Ledger, txn: Transaction) -> Result,
	Balance: (self: Ledger, owner: unknown, currency: Currency) -> number,
	Balances: (self: Ledger, owner: unknown) -> { [Currency]: number },
	HasApplied: (self: Ledger, owner: unknown, id: string) -> boolean,
	Export: (self: Ledger, owner: unknown) -> any,
	Import: (self: Ledger, owner: unknown, snapshot: any) -> (),
	Forget: (self: Ledger, owner: unknown) -> (),
	History: (self: Ledger, owner: unknown) -> { string },
}

function Ledger.new(options: Options): Ledger
	assert(#options.currencies > 0, "a ledger needs at least one currency")

	local currencies: { [Currency]: true } = {}
	for _, currency in options.currencies do
		assert(
			typeof(currency) == "string" and currency ~= "",
			"currency names must be non-empty strings"
		)
		currencies[currency] = true
	end

	return (
		setmetatable({
			_currencies = currencies,
			_maxBalance = options.maxBalance or MAX_SAFE_INTEGER,
			_allowCredit = options.allowCredit == true,
			_historyLimit = options.historyLimit or DEFAULT_HISTORY_LIMIT,
			-- owner -> { balances = {currency -> n}, applied = {id -> true}, order = {id} }
			_accounts = {} :: { [unknown]: any },
		}, Ledger) :: any
	) :: Ledger
end

function Ledger._account(self: any, owner: unknown)
	local account = self._accounts[owner]
	if account == nil then
		account = { balances = {}, applied = {}, order = {} }
		self._accounts[owner] = account
	end
	return account
end

--[[
	Apply a transaction. Never yields, never throws.

	Returns `replay = true` and the UNCHANGED balance when the id has already been applied.
	Note what that means for the caller: a replay is a SUCCESS (`ok = true`), because the
	transaction did happen -- just earlier. Treating a replay as a failure and retrying is
	how a retry loop becomes an infinite one.
]]
function Ledger.Apply(self: Ledger, txn: Transaction): Result
	local this = self :: any

	if typeof(txn.id) ~= "string" or txn.id == "" then
		return { ok = false, balance = 0, replay = false, reason = "missing transaction id" }
	end
	if not this._currencies[txn.currency] then
		return {
			ok = false,
			balance = 0,
			replay = false,
			reason = `unknown currency {tostring(txn.currency)}`,
		}
	end

	local delta = txn.delta
	if typeof(delta) ~= "number" then
		return { ok = false, balance = 0, replay = false, reason = "delta must be a number" }
	end
	-- NaN defeats every comparison below: `NaN > 0` and `NaN <= 0` are both false, so a
	-- bounds check would pass it straight through and poison the balance permanently.
	if delta ~= delta then
		return { ok = false, balance = 0, replay = false, reason = "delta is NaN" }
	end
	if delta == math.huge or delta == -math.huge then
		return { ok = false, balance = 0, replay = false, reason = "delta is infinite" }
	end
	-- Integers only. Fractional currency is a rounding-error dupe waiting to happen, and
	-- it serialises badly.
	if delta % 1 ~= 0 then
		return { ok = false, balance = 0, replay = false, reason = "delta must be an integer" }
	end

	local account = Ledger._account(this, txn.owner)
	local balance = account.balances[txn.currency] or 0

	-- THE IDEMPOTENCY CHECK, before anything is mutated.
	if account.applied[txn.id] then
		return { ok = true, balance = balance, replay = true }
	end

	local updated = balance + delta

	if not this._allowCredit and updated < 0 then
		return { ok = false, balance = balance, replay = false, reason = "insufficient funds" }
	end
	if updated > this._maxBalance then
		return { ok = false, balance = balance, replay = false, reason = "balance ceiling exceeded" }
	end

	account.balances[txn.currency] = updated
	account.applied[txn.id] = true
	table.insert(account.order, txn.id)

	-- Bound the retained ids. See the retention note in the README: an unbounded set grows
	-- a player's profile forever, and a profile that outgrows its DataStore limit stops
	-- saving entirely -- which loses far more than a stale id would.
	while #account.order > this._historyLimit do
		local evicted = table.remove(account.order, 1) :: string
		account.applied[evicted] = nil
	end

	return { ok = true, balance = updated, replay = false }
end

function Ledger.Balance(self: Ledger, owner: unknown, currency: Currency): number
	local account = (self :: any)._accounts[owner]
	if account == nil then
		return 0
	end
	return account.balances[currency] or 0
end

function Ledger.Balances(self: Ledger, owner: unknown): { [Currency]: number }
	local account = (self :: any)._accounts[owner]
	if account == nil then
		return {}
	end
	return table.clone(account.balances)
end

--[[
	Has this id already been applied? Note the honest limitation: this answers "is it in the
	retained window", not "did it ever happen". Beyond historyLimit the answer is false even
	for an id that was applied.
]]
function Ledger.HasApplied(self: Ledger, owner: unknown, id: string): boolean
	local account = (self :: any)._accounts[owner]
	return account ~= nil and account.applied[id] == true
end

function Ledger.History(self: Ledger, owner: unknown): { string }
	local account = (self :: any)._accounts[owner]
	if account == nil then
		return {}
	end
	return table.clone(account.order)
end

--[[
	A serialisable snapshot for persistence (lapis, or whatever you use).

	The applied-id list is part of the snapshot and MUST be persisted with the balances.
	Saving balances without it means a rejoin loses every idempotency record, and the first
	retried transaction after that is a dupe.
]]
function Ledger.Export(self: Ledger, owner: unknown): any
	local account = (self :: any)._accounts[owner]
	if account == nil then
		return { balances = {}, applied = {} }
	end
	return {
		balances = table.clone(account.balances),
		applied = table.clone(account.order),
	}
end

--[[
	Restore a snapshot. Unknown currencies in the snapshot are DROPPED rather than trusted:
	stored data outlives every assumption in the code that wrote it, and a currency that no
	longer exists should not resurrect itself.
]]
function Ledger.Import(self: Ledger, owner: unknown, snapshot: any): ()
	local this = self :: any
	local account = Ledger._account(this, owner)
	table.clear(account.balances)
	table.clear(account.applied)
	table.clear(account.order)

	if typeof(snapshot) ~= "table" then
		return
	end

	if typeof(snapshot.balances) == "table" then
		for currency, amount in snapshot.balances do
			if
				this._currencies[currency]
				and typeof(amount) == "number"
				and amount == amount
				and amount % 1 == 0
			then
				account.balances[currency] = math.clamp(amount, -this._maxBalance, this._maxBalance)
			end
		end
	end

	if typeof(snapshot.applied) == "table" then
		for _, id in snapshot.applied do
			if typeof(id) == "string" and not account.applied[id] then
				account.applied[id] = true
				table.insert(account.order, id)
			end
		end
		while #account.order > this._historyLimit do
			local evicted = table.remove(account.order, 1) :: string
			account.applied[evicted] = nil
		end
	end
end

--[[ Drop an owner entirely. Call on PlayerRemoving, AFTER the profile has saved. ]]
function Ledger.Forget(self: Ledger, owner: unknown): ()
	(self :: any)._accounts[owner] = nil
end

return Ledger
