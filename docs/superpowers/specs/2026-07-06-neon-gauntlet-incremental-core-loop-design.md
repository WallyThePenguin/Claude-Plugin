# NEON GAUNTLET — Incremental Pivot: Core Loop (Sub-project 1) — Design

**Date:** 2026-07-06
**Status:** Design for review
**Author:** brainstorm (WallyThePenguin + Claude)

## 1. What we're building & why

Pivot the existing GUI-only tower-defense (`game/GauntletGlory/Main.client.luau`, ~1.4k lines, built
on the `ReplicatedStorage.UIEngine` framework) into a **Roblox incremental "simulator"**. The genre's
engine is *exponential number-go-up* driven by an upgrade → currency → prestige loop.

The **selling point is the tower-defense / defensive theme** — the clicker must *reinforce* defense,
not replace it. So the game is a **tower-defense CLICKER incremental**: enemies march the neon lane
toward the Core, the player **taps** invaders to strike them (active DPS) while **summoned fighters**
auto-attack (passive DPS); kills drop currency; the whole thing is wrapped in a gacha + upgrade +
prestige progression.

### The full vision (decomposition — for context, not all in this spec)

A full shippable simulator is several independent subsystems, dependency-ordered:

1. **Core incremental loop** *(this spec — client, build first)* — earning, summon, upgrades, one
   prestige layer, big numbers, idle. Validates "is it fun?" single-player.
2. **Persistence & server-authoritative economy** — move state to the server + DataStore
   (ProfileService), anti-exploit validation.
3. **Monetization** — gamepasses (2× coins, auto-summon, VIP, +slots) + dev products, MarketplaceService.
4. **Retention & social** — daily rewards, quests, codes, limited-time events, leaderboards, index.
5. **Trading** — secure player-to-player trading. Highest risk, last.

Each gets its own spec → plan → build. **This spec is only sub-project 1.** We validate the fun loop
client-side, then sub-project 2 serverizes it — so this design keeps all game state in one
JSON-serializable store to make that migration a move-modules job, not a rewrite.

## 2. Core loop (agreed)

- **Tap** a marching enemy → deal Tap Damage. **Fighters** placed on the lane auto-deal Fighter DPS.
  Enemy dies → drops **¥**.
- Enemies scale in HP and ¥ reward as the **wave** climbs (endless).
- The **Core** has HP. Enemies that reach it chip its HP. At 0 → **soft setback**: pushed back a few
  waves ("core rebuilding" pause) and forfeit only the current run's *uncollected* ¥. All permanent
  progress (Honor, permanent tree, unlocks) persists. **Safe to AFK** — fighters + auto-earning
  continue without the player.
- **Prestige (Rebirth)** at a ¥/wave threshold: reset ¥ + run-upgrades + fighters for **Honor** +
  a permanent global multiplier; spend Honor in a **permanent tree** that persists forever (incl.
  auto-buyers, global multipliers, and deep unlocks). Numbers grow, prestige resets keep it fresh.

## 3. Architecture — modular client refactor (agreed)

The current single LocalScript becomes a set of **ModuleScripts** under a shared folder, required by
thin client entry scripts. The existing `UIEngine` stays as the presentation framework and is reused.
The current game's combat/enemies/fighters/lane become the **Combat + UI** layer consuming the new
systems. Pure-logic modules are unit-testable via `run_luau` in the edit context (no playtest needed) —
a testability win of the split.

| Module | Responsibility | Depends on |
|---|---|---|
| `BigNum` | big-number arithmetic (mantissa/exponent) + suffix formatting ("1.23 Qa") | — |
| `Balance` | ALL tuning constants + cost/scaling curves (single source of truth) | BigNum |
| `State` | the `PlayerState` store: get/set/subscribe (reactive), JSON-serializable | — |
| `Combat` | waves, enemies, tap damage, fighter DPS aggregation, Core HP, soft setback | State, Balance, BigNum |
| `Summon` | gacha roll (rarity weights), duplicate merge → level | State, Balance |
| `Upgrades` | run-upgrade buy/cost/effect + auto-buyer execution | State, Balance, BigNum |
| `Prestige` | rebirth eligibility + Honor calc + permanent-tree nodes | State, Balance, BigNum |
| `Idle` | offline-earnings calc on load | State, Balance, BigNum |
| `UI` (+ existing `UIEngine`) | all screens; subscribes to State | State, Combat, Summon, Upgrades, Prestige |

The current top-down fighters, creature enemies, smooth lane, ranges, and premium GUI are **preserved**
as the Combat/UI presentation — this is a systems refactor around them, not a visual redo.

## 4. Systems detail (v1)

### 4.1 BigNum + formatting
Store large values as `{m, e}` (mantissa 1–10, exponent) once past `2^53`. Support +, ×, compare,
and `format()` → suffix notation (K, M, B, T, Qa, Qi, Sx, Sp, Oc, No, Dc, …). All displayed numbers
route through `BigNum.format`. Small values stay plain Lua numbers for speed; promote on overflow.

### 4.2 Combat / earning
- **Tap damage** = `Balance.tapBase × mult(runUpgrades.tapDmg) × permMult.tap × globalMult`.
- **Fighter DPS** (per placed fighter) = `Balance.classBase[class] × rarityMult[rarity] × levelMult(level)
  × mult(runUpgrades.fighterDmg) × permMult.dps × globalMult`. Aggregated each tick.
- **Enemy HP(w)** = `Balance.enemyHpBase × Balance.enemyHpGrowth^w`; **¥ reward(w)** =
  `Balance.yenBase × Balance.yenGrowth^w × mult(runUpgrades.yenMult) × permMult.yen`.
- **Core HP** = `Balance.coreHpBase × mult(runUpgrades.coreHp) × permMult.coreHp`; leaked enemy deals
  its remaining HP fraction as core damage. At 0 → setback (wave −`Balance.setbackWaves`, clamp ≥ 1;
  brief invuln rebuild; drop uncollected ¥ buffer).
- Endless waves; wave advances when its enemies are cleared (spawner keeps feeding while AFK).

### 4.3 Summon (gacha)
- **Roster (v1):** the 4 classes (Ronin/Onmyoji/Archer/Monk) × **7 rarities** (Common, Uncommon, Rare,
  Epic, Legendary, Mythic, Secret). Rarity sets a DPS multiplier and a summon weight; named
  variant-skins are later polish.
- **Roll:** spend ¥ (cost scales with total summons); weighted-random rarity (modified by Summon Luck),
  then random class → a `{class, rarity, level=1}` fighter into inventory.
- **Merge:** duplicates of the same `(class, rarity)` auto-merge; each duplicate = `+1 level`,
  `levelMult(level) = 1 + Balance.perLevel × (level−1)`.
- **Placement:** keep free-placement on the lane; active **slots** start at `Balance.startSlots` and
  increase via a run upgrade + a permanent node. Unplaced fighters sit in inventory (and are merge fuel).

### 4.4 Run upgrades (reset on prestige)
Six, each with a scaling cost curve `cost(lvl) = base × growth^lvl`:
`tapDmg`, `fighterDmg`, `yenMult`, `luck` (summon odds), `coreHp`, `slots`. Bought with ¥.

### 4.5 Prestige (Rebirth) — the meta
- **Eligible** at `wave ≥ Balance.prestigeWave` (or ¥ ≥ threshold).
- **Honor gained** = `floor(Balance.honorK × sqrt(totalRunYen))` (diminishing, rewards deeper runs).
- **Reset:** ¥ → start, run upgrades → 0, fighters → wiped, wave → 1. **Keep:** Honor, permanent tree,
  permanent unlocks, permanent fighters (once that node is owned).
- **Permanent tree** (Honor-bought, persists forever). v1 nodes:
  - **Auto-buyer: Tap Damage** (unlocks auto-purchase of the tapDmg run-upgrade; more auto-buyers are
    later nodes) — the automation-via-prestige hook.
  - **Global ¥ Multiplier**, **Global DPS Multiplier**, **Summon Luck+**, **Offline Rate+**,
    **Starting ¥**, **+Fighter Slot**.
  - **Unlock stubs (designed, not fully wired in v1):** new banner, extra upgrade tree, first
    **permanent-fighter** slot — nodes exist in `Balance` with clear TODO gates for later sub-projects.

### 4.6 Idle / offline
On load, `Idle` computes `min(now − state.lastSeen, Balance.offlineCap) × passiveRate × permMult.offline`
and grants ¥. `lastSeen` stamped on save/close. (Client-side v1; server-validated in sub-project 2.)

## 5. UI screens (v1, on UIEngine)
- **Main:** combat board (lane + enemies + fighters + Core) + HUD (¥, Honor, wave, Core HP bar) +
  tap interaction + bottom nav (Summon / Upgrades / Prestige).
- **Summon:** banner art + roll button (shows cost) + reveal animation + fighter inventory (place / view
  level) .
- **Upgrades:** run-upgrade rows (level, cost, buy) + auto-buyer toggles (shown once unlocked).
- **Prestige:** rebirth button (shows Honor gain + confirm) + the permanent tree (nodes, costs, owned).

## 6. Data model — `PlayerState` (one serializable table)
```
{
  yen, honor, wave, lastSeen,
  runUpgrades = { tapDmg, fighterDmg, yenMult, luck, coreHp, slots },  -- levels
  permUpgrades = { yenMult, dpsMult, luck, offline, startYen, slots, autoTap, ... },  -- levels/owned
  fighters = { { class, rarity, level, placed:bool, pos:{x,y} }, ... },
  unlocks = { banner2=false, tree2=false, permFighter=false },
  stats = { totalYen, prestiges, summons },
}
```
Everything the game reads/writes lives here so sub-project 2 can serialize it to DataStore verbatim
and move the mutators server-side.

## 7. v1 scope boundary
**In:** modular refactor; BigNum + formatting; tap + fighter earning; endless waves; Core HP + soft
setback; summon gacha (4×7, merge-level); 6 run upgrades; ONE prestige layer + starter permanent tree
(incl. the first auto-buyer); offline earnings (client); the 4 UI screens on UIEngine.
**Deferred (later sub-projects):** server/DataStore; Robux monetization; worlds/zones; multiple
upgrade trees; permanent-fighter tiers beyond the first stub; events; trading; leaderboards.

## 8. Testing / verification
- **Logic modules** (BigNum, Balance curves, Summon odds distribution, Prestige/Honor math, offline
  calc): unit-test via `run_luau` in the edit context — assert-based, no playtest.
- **Combat + UI:** the established headless `studio-agent.ps1 play start/capture` loop with a `DEBUG`
  auto-driver (auto-tap, fast-forward waves, force-prestige) for visual verification.
- **Save round-trip:** serialize `PlayerState` → JSON → deserialize → assert equal (readies sub-project 2).

## 9. Open decisions for the planning phase
- Exact `Balance` starting constants (cost bases/growths, rarity weights + multipliers, honor curve) —
  tuned during implementation via the test harness; the plan will seed sensible first values.
- Where the modules live (a `ReplicatedStorage.Game` folder vs alongside `UIEngine`) — a mechanical
  choice finalized in the plan.
