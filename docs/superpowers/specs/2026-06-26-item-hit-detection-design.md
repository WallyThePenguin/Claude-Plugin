# Item Hit Detection (roadmap #4) — design

**Date:** 2026-06-26
**Status:** design (autonomous, from the roadmap memory `studio-agent-interactive-items-roadmap`).
**Serves:** the interactive-items vision — #1 mesh→Tool, #2 use-animation, #3 behavior state machine,
**#4 hit detection (this)**, #5 PvE NPCs.
**Builds on:** #3 (`src/Tools/ItemBehavior.luau`, the `ItemState` attribute + `StateChanged` BindableEvent, the
ACTIVE WINDOW). Spec `docs/superpowers/specs/2026-06-26-item-behavior-state-machine-design.md`.

## Purpose

On the item's **ACTIVE WINDOW** (#3), find targets and apply an effect (damage). Targets are `Humanoid`s
(the #5 PvE NPCs). This is the foundation for the project's **netcode** — client requests, server executes —
with the heavy lag-compensation / anti-cheat / per-limb work explicitly DEFERRED to the dedicated netcode
effort (the user's "dev-loop now, ship-grade netcode later").

## The replication reality (LIVE-established this session, drives the architecture)

- #3's state machine runs **client-side** (`ItemBehaviorRuntime` LocalScript); `ItemState` + `StateChanged` are
  client-side and **do NOT replicate to the server** (confirmed: a server probe couldn't read the client-set
  `ItemState`, which is why #3's `record` verb samples it on the client).
- `Humanoid.Health` is **server-authoritative** — a client cannot reliably damage a server-owned NPC's
  Humanoid.
- Therefore hit detection that actually damages NPCs MUST execute on the **server**, requested by the client at
  the active window. This is not optional; it is the only correct shape, and it is the netcode foundation.

## Architecture — client-request → server-execute

1. **Client** (at active-window enter): a hitbox client script connects the tool's `StateChanged`; when state
   becomes `active` it fires a RemoteEvent (`ItemHitRequest`) — "I am swinging now." (Decoupled: it uses #3's
   `StateChanged` hook, it does not modify the #3 runtime.)
2. **Server** (on `ItemHitRequest` from player P): find P's character + its equipped Tool's `Handle`; sweep a
   hitbox (a `reach`-radius region around the Handle via `workspace:GetPartBoundsInRadius`); collect every
   `Humanoid` whose character is NOT P's; `TakeDamage(damage)` once per target per swing (a dedup set, fresh
   per request); optionally fire a `Hit` BindableEvent for VFX/knockback hooks.
   - **SERVER-AUTHORITATIVE:** the server decides the hit; the client only requests the moment. The dev-loop
     server is naive (no rewind/validation). The netcode effort later adds: rewind-to-swing-time positions
     (lag comp), request validation (is the player actually mid-swing? cooldown elapsed? reach sane?),
     reconciliation, and anti-cheat — without changing this request→execute seam.

## `bind_hitbox(tool, damage?, reach?)`

1. Resolve the Tool (must be a `Tool` with a `Handle`; should have #3's `StateChanged` — WARN if no
   `bind_behavior` yet, since without an active window nothing fires).
2. Attributes on the Tool: `HitDamage` (default 25), `HitReach` (default 6 studs).
3. Ensure a shared `RemoteEvent` `StudioAgentItemHit` in `ReplicatedStorage` (RemoteEvents must live in a
   replicated container; one shared event, the request identifies the player → the server finds their tool).
4. Write a CLIENT `ItemHitClient` LocalScript into the Tool: connect `StateChanged`; on `active`, fire the
   RemoteEvent.
5. Write a SERVER `ItemHitServer` Script into the Tool: on the RemoteEvent from the wielder, run the sweep +
   damage above. (A Script inside a Tool runs server-side while the Tool is in the player's Backpack/Character;
   the LocalScript runs client-side there — self-contained, ships with the tool.)
6. Return a summary: damage, reach, the request→execute flow, and that lag-comp/anti-cheat are the later netcode
   layer. **Destructive**, **RELAY**, parent-only.

## Composition / order

`… → bind_animation → bind_behavior → bind_hitbox`. `bind_hitbox` needs #3's `StateChanged`; run it after
`bind_behavior`. Re-binding behavior keeps the hitbox scripts (they only depend on `StateChanged`, which
`bind_behavior` re-creates).

## Verification (live, via the play bridge)

- Spawn a **target dummy** (an R15 block rig with a `Humanoid`, via `spawn_rig`/NativeRig) a few studs in front
  of the player. `bind_hitbox` on `StarterPack.UseSword`.
- `play start` → position the player facing the dummy → `play act record` (equips + activates → the client
  fires the request at the active window → the server sweeps + damages). Read the dummy's `Humanoid.Health`
  **server-side** (it is server-owned, so it is readable + authoritative) before/after: it must drop by
  `HitDamage`. A second swing on cooldown must NOT double-hit within one active window (dedup).
- `BehaviorFactory`-style pure helper if any geometry math is worth isolating; `RelaySpec` no-drift
  (`bind_hitbox` relays).

## Scope / non-goals

- **IN:** `bind_hitbox`, the client-request→server-execute hit detection, server-authoritative damage on the
  active window, a `Hit` hook.
- **OUT (the dedicated netcode effort):** lag compensation (rewind to swing-time positions), server-side
  validation / anti-cheat / reconciliation, **per-limb hit + dismemberment + reaction state** (the lightsaber
  vision). #4 establishes the request→execute seam these harden.
- **OUT (#5):** the NPCs/AI themselves — #4 damages ANY non-wielder Humanoid; #5 gives those Humanoids
  behavior + health/death.
- **OUT:** ranged/projectile weapons (this is a melee sweep; a projectile path is a later variant).
