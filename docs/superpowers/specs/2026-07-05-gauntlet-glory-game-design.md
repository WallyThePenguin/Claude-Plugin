# GAUNTLET & GLORY — GUI roguelite TD + duel game — design

**Date:** 2026-07-05 · **Status:** approved by user ("do it"); synthesized from a 4-designer + judge workflow.

## Vision (user's)
Infinite roguelite tower-defense, ONE life. During the run you forge a "class"; then you
duel that class 1v1 against other real players' classes (a different, active format, not TD).
GUI-only (no meshes — sidesteps the mesh-asset instability).

## The loop
Survive an endless one-life TD → forge a Champion from your build → async duel vs real
players' Champion snapshots on an Elo ladder → climb → re-forge smarter.

## TD format (GUI)
- **Single vertical lane**: one tall Frame; enemies spawn at TOP as pooled rounded Frames
  (color=type, HP label + HP-bar child), tween DOWN toward a **Core** bar at the bottom.
- **One Heartbeat loop** advances each enemy `progress` 0→1; `pos = top + progress*height`.
  Hard **live-enemy cap** + spawn queue (excess enemies wait) so the frame budget is bounded.
- **8 tower slots** (4 per side). Click empty slot → radial pick of owned towers → tower Frame
  auto-fires at enemies in its vertical range band via **instant hitscan-flash** (a rotated
  thin Frame for ~0.1s) — never a simulated projectile. Damage-number popups, death pop-scale,
  coins fly to a counter.
- **ONE LIFE**: Core = 1 HP. Any enemy reaching the Core line ends the run instantly
  (screen-shake + red flash + slow-mo → run summary "You reached Wave N").
- **Wave scaling** (pure formula, infinite): wave N spawns `~8 + N*1.5` enemies, HP `base*1.18^N`,
  speed ramps; every 5th wave = ELITE (one tanky Frame), every 10th = SWARM (many fast weak).

## Roguelite layer
Between every wave a 3-card **draft** slides up (hover-scale juice). Card types: NEW TOWER,
UPGRADE (buff/evolve an owned tower), PERK (global run modifier — never adds lives). Coins
(from kills) fuel **reroll**/**banish**. Every card shows a **dual tooltip**: "In the Gauntlet:
<TD effect> / In the Arena: <duel effect>" so the player consciously forges their duelist.
A live **BUILD TRAY** shows the growing class. Accumulates into `RunState`.

## Tag / set-bonus + archetype (depth)
Towers/upgrades carry **tags** (Cold/Toxic/Electric/Fortify/Support...). Crossing an ownership
threshold unlocks a mid-run **set bonus** (e.g. "3 Cold → frozen enemies shatter for AoE"), which
also carries into the duel as a passive. The dominant tag → an **archetype label**
(Cryomancer/Plaguebringer/Overloader/Bulwark) on the Champion card + matchmaking flavor.

## Class model (the bridge)
`RunState` = `{ownedTowers, per-tower upgrade stacks, perks, tags, wavesSurvived, perTowerDamage}`.
**`ForgeChampion(runState) -> ChampionSnapshot`** is a single PURE, golden-tested function:
- the **top-4 damage** towers → 4 duel **ability cards** (same icon/color, scaled by upgrade stacks),
- perks → passives, tag-thresholds → set-bonus passives, dominant tag → archetype,
- `wavesSurvived` → a power tier (normalized + **clamped** so no god-build auto-wins).
The SAME function runs on your save and on a loaded opponent snapshot → identical rules, no desync.
`ChampionSnapshot ≈ 1-3KB` pure data: `{ownerName, ownerUserId, rating, archetype, tier, stats,
abilities[4], passives[], seed}` — exactly what DataStore stores.

## PvP model (async, real players)
Active real-time **cooldown brawl** (NOT TD): two portraits + HP/energy bars; your 4 ability
cards with cooldown radials + a Guard reaction. Opponent = a **snapshot of a real player's
Champion** from a rating-bucketed OrderedDataStore, driven by a deterministic **DuelAI** (priority
policy from its archetype), **matchId-seeded** so the fight is reproducible + server re-simmable
(anti-cheat). **Element-counter triangle** (Cold>Electric>Toxic>Cold, ~1.4x) so timing + counter-
building matter over raw stats. **House-champion fallback** bank so a thin ladder is never empty.
Win/loss → Elo update (pure `RatingLadder`). ~30-60s per duel, zero lobby/lag.

## Module architecture (GUI-only ScreenGui/Frames/Luau)
`Theme` (palette/fonts/tween presets) · `FeedbackFX` (juice primitives: dmg popup, death pop,
coin-fly, shake, wave banner) · `Config` (board/wave/tower/perk/ability data) · `GameController`
(state machine: Menu→TDRun→Summary→Duel→Ladder; owns ScreenGui root) · `LaneView` (lane + slots +
Core + enemy Frame pool + Heartbeat movement) · `WaveDirector` (pure spawn schedule) · `EnemyPool`
(pooled Frames) · `TowerSystem` (placement/targeting/hitscan/upgrades) · `TowerDefs` (SINGLE source:
stats+range+upgrade+tags+duel-ability mapping+dual-tooltip strings) · `Economy` (coins) ·
`RunState` (accumulating serializable table + per-tower damage) · `DraftSystem` (weighted draw +
draft UI) · `SetBonus` (tag thresholds; consumed by TowerSystem + ForgeChampion) · `ForgeChampion`
(pure bridge) · `DuelView` (two-portrait battler) · `DuelEngine` (seeded active sim) · `DuelAI`
(archetype priority) · `RatingLadder` (Elo, pure) · `LadderStore` (server: DataStore snapshot save +
OrderedDataStore matchmaking + house fallback + Elo write) · `Net` (thin Remote layer, trust boundary).

## MVP build order (first slice — single-player, no DataStore)
1. `Theme` + `FeedbackFX` — palette/fonts/tween presets + juice primitives.
2. `LaneView` + `EnemyPool` + one Heartbeat loop — vertical lane, Core (1HP), 8 slots, ~40 pooled
   enemies, cap+queue. **Prove the render is stable + smooth first.**
3. `WaveDirector` + one-life fail — spawn schedule, instant run-end on leak, run summary.
4. `TowerSystem` + `TowerDefs` (Cannon/Splinter/Frost) + `Economy` — click slot → auto-fire hitscan,
   dmg pops, coins. First complete TD combat loop.
5. `DraftSystem` + `RunState` + dual tooltips — 3-card draft between waves, live build tray.
6. `ForgeChampion` (pure + golden test) + per-tower damage tracking — top-4 towers → 4 duel cards.
7. `DuelView` + `DuelEngine` + `DuelAI` vs ONE hardcoded house Champion — active cooldown brawl.
   **Loop closes single-player: die → forge → duel → retry.** (Ship/playtest.)

Then layer: `LadderStore` (DataStore + OrderedDataStore + house fallback) → `RatingLadder` Elo +
server re-sim → reroll/banish + perks + set-bonus/archetype + element triangle → full tower set →
elite/swarm variants → audio/cosmetic polish. Each layer bolts onto proven rails.

## Where it lives
A `ScreenGui` under `StarterGui` (client-authoritative for the MVP), with ModuleScripts. No meshes,
no parts, no DataStore in the MVP — everything reversible; the place is not saved until we choose to.

## Testing
- Pure modules (`WaveDirector`, `ForgeChampion`, `RatingLadder`, `SetBonus`) unit-tested (golden
  inputs → outputs).
- Render/loop live-verified via playtest_capture (lane renders, enemies move, death fires).
