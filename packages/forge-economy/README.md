# forge-economy

Idempotent currency and purchase transactions with anti-dupe guarantees.

**Server realm only.** Mount under `ServerScriptService` via Forest's two-manifest pattern.

## Install

```sh
forest i @Valid/forge-economy
```

## The one property everything else is subordinate to

> **Applying the same transaction twice has the same effect as applying it once.**

Economy bugs are the ones you cannot walk back. A combat bug annoys players for an evening;
a dupe permanently devalues every currency in the game, and there is no honest rollback once
the duplicated goods have been spent and traded.

Idempotency matters because **retries are routine, not exceptional**: a DataStore write fails
and is retried, a player rejoins mid-purchase, Roblox redelivers a receipt until you return
`PurchaseGranted`. Every one of those replays a transaction. A ledger that adds the amount
again on each is a dupe generator with extra steps.

## The other half is ordering — and it's an API design choice

`Apply` is **synchronous and never yields**. That's deliberate. The classic dupe is a
read-modify-write split across a yield, where two interleaved requests both read the
pre-write balance. **You cannot write that bug against this API, because there is nowhere to
yield.** Persistence is the caller's job (`Export`/`Import`, e.g. into `nezuo/lapis`).

## Usage

```lua
local Economy = require(ServerPackages["forge-economy"])

local ledger = Economy.Ledger.new({ currencies = { "coins", "shards" } })

-- Transaction ids are SERVER-generated. Never let a client supply one: a client that picks
-- the id decides whether their purchase is a replay, which hands them the dupe directly.
local result = ledger:Apply({
    id = HttpService:GenerateGUID(false),
    owner = player.UserId,
    currency = "coins",
    delta = -250,
    kind = "purchase",
    meta = { item = "ember-falchion" },
})

if result.ok then
    -- A replay is a SUCCESS: the transaction happened, just earlier. Treating it as a
    -- failure and retrying is how a retry loop becomes an infinite one.
    if not result.replay then
        inventory:Grant(player, "ember-falchion")
    end
else
    warn(`[economy] rejected: {result.reason}`)
end
```

### Persistence

```lua
profile.Data.economy = ledger:Export(player.UserId)      -- on save
ledger:Import(player.UserId, profile.Data.economy)       -- on load
```

**Save the applied-id list with the balances.** It's part of `Export` for a reason: balances
alone means a rejoin loses every idempotency record, and the first retried transaction after
that is a dupe.

## Real-money purchases

`Receipts` is a **separate store** from the ledger, with much longer retention and loud
eviction. Soft-currency idempotency can afford a bounded window — a retry that arrives after
eviction is a rounding error in a made-up currency. A Robux receipt cannot: Roblox redelivers
it across server restarts and rejoins, and an aged-out record is a double-grant of something
the player paid actual money for.

### The ordering rule — get this wrong and you double-grant or lose purchases

1. **Already granted?** → return `PurchaseGranted` immediately. Do **not** grant again.
2. **Not granted?** → apply the grant, mark it, and **persist the profile**.
3. **Only after the save succeeds** → return `PurchaseGranted`.

```lua
MarketplaceService.ProcessReceipt = function(info)
    local key = info.PurchaseId
    if receipts:IsGranted(info.PlayerId, key) then
        return Enum.ProductReceiptProcessingError.PurchaseGranted
    end

    grantProduct(info.PlayerId, info.ProductId)
    receipts:MarkGranted(info.PlayerId, key, { productId = info.ProductId })

    if not saveProfile(info.PlayerId) then
        -- Correct and safe: Roblox retries, and step 1 makes the retry harmless.
        return Enum.ProductReceiptProcessingError.NotProcessedYet
    end
    return Enum.ProductReceiptProcessingError.PurchaseGranted
end
```

Returning `PurchaseGranted` *before* the save lands is the classic mistake: Roblox considers
the purchase settled and stops retrying, the server dies before the write, and the player has
paid for nothing.

## API

### `Ledger.new({currencies, maxBalance?, allowCredit?, historyLimit?})`

`Apply(txn) -> {ok, balance, replay, reason?}`, `Balance(owner, currency)`,
`Balances(owner)`, `HasApplied(owner, id)`, `History(owner)`, `Export(owner)`,
`Import(owner, snapshot)`, `Forget(owner)`.

Rejects, in order: missing id, unknown currency, non-number / **NaN** / infinite /
non-integer delta, overdraw (unless `allowCredit`), balance ceiling.

- **Integers only.** Fractional currency is a rounding-error dupe waiting to happen and it
  serialises badly.
- **NaN gets its own check.** `NaN > 0` and `NaN <= 0` are both false, so a bounds check
  passes it straight through — and it then poisons the balance permanently, including in
  saved data.
- **Unknown currencies are rejected, not created.** A typo should not silently mint a
  parallel wallet.
- **A rejected transaction is not recorded**, so a later valid transaction reusing that id
  still works.
- `maxBalance` defaults to 2^53 — past that, integer arithmetic in a 64-bit float stops
  being exact and a balance is no longer the number it claims to be.

### `Receipts.new({limit?, onEvict?})`

`IsGranted(owner, receiptId)`, `MarkGranted(owner, receiptId, record?)`,
`Get(owner, receiptId)`, `Count(owner)`, `Export(owner)`, `Import(owner, snapshot)`,
`Forget(owner)`.

## The retention trade, stated honestly

`historyLimit` (default 256) bounds retained transaction ids per owner. **Beyond that window
a replay is no longer detectable** — `HasApplied` returns false for an id that really was
applied.

That is a deliberate trade, not an oversight. An unbounded set grows a player's profile
forever, and a profile that outgrows its DataStore size limit **stops saving entirely**,
which loses far more than a stale id ever would. 256 covers any realistic retry horizon;
retries arrive in seconds, not days.

Receipts default to 2048 and fire `onEvict` when they overflow. **Make that loud in
production** — it means a player has bought so many products that the oldest record is gone,
and a very late redelivery would double-grant.

## Not included

**Inventory / item stacks.** Deliberately not built yet: item semantics depend on decisions
Forge Arena hasn't made (are cosmetics unique or stackable? tradeable? is there a cap?), and
guessing produces an API that has to be broken later. The ledger's idempotency machinery is
the reusable half and it's here.

## License

MIT
