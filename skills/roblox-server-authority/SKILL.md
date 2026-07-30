---
name: roblox-server-authority
description: Use when writing or reviewing any Roblox code that crosses the client/server boundary — RemoteEvents and RemoteFunctions, damage and hit detection, currency or inventory changes, movement, or anything a player could exploit. Triggers on "RemoteEvent", "RemoteFunction", "FireServer", "InvokeServer", "anti-cheat", "exploit", "server-authoritative", "validate input", "rate limit", or a review of gameplay code that awards, spends, or damages.
---

# Server authority and anti-exploit

The threat model is simple and absolute: **a player controls their client completely.**
They can call any RemoteEvent with any arguments at any rate, read anything that
replicates, and modify any local script. Nothing that runs on the client is a
security boundary — not obfuscation, not a client-side check, not a UI that hides a button.

## The one rule

**The server decides. The client requests and displays.**

Every exploit in a Roblox game is a violation of that sentence. Write it on the wall.

## Validate every remote argument, in this order

A remote handler that reads `amount` before checking it is already broken. Validate in
order, and reject — never coerce:

1. **Arity** — the client can send zero arguments, or fifty.
2. **Type** — `typeof(x) == "number"`, and for instances `x:IsA("BasePart")`.
3. **Finiteness** — `x == x and x ~= math.huge and x ~= -math.huge`. `NaN` defeats every
   comparison you're about to write: `NaN > 0` is false *and* `NaN <= 0` is false.
4. **Range** — bounded on both ends. Integers: `x % 1 == 0`.
5. **Ownership** — is this instance one the caller may act on? Does that item exist in
   *their* inventory, on the server's copy?
6. **State** — is the round even running? Are they alive? Do they have the tool equipped?
7. **Rate** — per-player, per-remote. A valid call at 500 Hz is an attack.

```lua
-- The shape every handler should have.
local MAX_STAKE = 1000

local function onStake(player: Player, amount: unknown)
    if typeof(amount) ~= "number" then return end
    if amount ~= amount then return end              -- NaN
    if amount % 1 ~= 0 then return end               -- integers only
    if amount < 1 or amount > MAX_STAKE then return end
    -- ...only now is `amount` a number you may reason about.
end
```

**Never trust a client-supplied Instance reference blindly.** A player can pass any
instance they can see, including someone else's character or a part they created.

## Rate limiting

Every remote needs a budget. Cheapest correct implementation is a token bucket per
(player, remote):

- Refill at the maximum *legitimate* rate, with a small burst allowance for lag.
- Over budget → drop the call silently and increment a counter.
- Counter over threshold → that's a signal worth acting on, not just logging.

Clean up on `PlayerRemoving`, or the table is a leak.

## Damage and hit detection

This is where "server-authoritative" gets misunderstood. Fully server-side hit detection
feels awful at 150 ms ping, and pure client-reported hits are a free aimbot. The
production answer is neither:

- The client reports **intent**: "I swung at time T, aiming here."
- The server **re-simulates** the hit against positions it recorded at time T, within a
  bounded rewind window (~200–250 ms; beyond that, reject).
- The server checks what the client cannot be trusted on: cooldown elapsed, weapon
  actually equipped, target alive, **range plausible given the recorded positions**, line
  of sight, target on a damageable team.
- The server applies damage and replicates the result. The client's local hit effect is
  cosmetic and may be wrong.

The rewind window is the whole design. Without it you punish high-ping players; unbounded,
you let a client claim a hit on a target who moved away seconds ago.

## Movement

Don't try to fully authoritate movement — Roblox replicates character physics from the
client by design, and fighting that produces rubber-banding. Do run **sanity checks**:

- Speed over a window, not per-frame (per-frame is all false positives).
- Teleport distance between samples.
- Vertical position outside the map's plausible band.
- Being somewhere unreachable — inside geometry, outside the arena bounds.

Treat a violation as **evidence**, not proof. Accumulate a score, act on the score. A
single spike is lag; a sustained pattern is a cheat.

## Things that are not security

- Hiding a UI button. The remote is still callable.
- Checking cooldown on the client. It's advisory, for feel.
- `RemoteEvent` names that are hard to guess. They're enumerable.
- Obfuscated local scripts. Trivially dumped.
- Putting a module in `ReplicatedStorage` "but not requiring it on the client". It
  replicated; it's readable.

Server-only code goes in `ServerScriptService` / `ServerStorage`. For Forest packages,
that's the two-manifest pattern — see `skills/forest-use`.

## Economy: idempotency and the dupe

Currency and inventory need one property beyond validation: **every mutation is idempotent
and ordered.**

- Give each transaction a server-generated id, and record applied ids.
- A retried or replayed request with a known id is a no-op, not a second grant.
- Never read-modify-write across a yield. Two remotes interleaving across a
  `DataStore:GetAsync()` is the classic dupe — the second read sees the pre-write balance.
- Serialise per-player mutations through one queue, or hold a lock for the whole
  read-modify-write.
- Log the ledger, not just the balance. A balance with no history is unauditable, and
  you will need to audit it.

## Review checklist

For any diff that crosses the boundary:

- [ ] Every remote handler validates arity, type, finiteness, range, ownership, state.
- [ ] Every remote has a per-player rate limit.
- [ ] No client-supplied value is used as an index, amount, or target without a check.
- [ ] Damage is resolved server-side against server-recorded positions.
- [ ] Rewind windows are bounded.
- [ ] Currency/inventory mutations are idempotent and don't read-modify-write across a yield.
- [ ] Nothing secret is in a replicated container.
- [ ] Violations increment a counter that something actually reads.
- [ ] `PlayerRemoving` cleans up every per-player table.
