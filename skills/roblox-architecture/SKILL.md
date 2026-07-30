---
name: roblox-architecture
description: Use when structuring a Roblox game's codebase — service lifecycle and bootstrapping, what lives on server vs client vs shared, how state replicates, Rojo project trees, or deciding where a new system belongs. Triggers on "project structure", "architecture", "where should this live", "bootstrap", "service", "singleton", "replicate state", "Rojo tree", "ReplicatedStorage vs ServerScriptService".
---

# Roblox game architecture

## Three realms, one rule each

| Realm | Container | Rule |
|---|---|---|
| **Server** | `ServerScriptService`, `ServerStorage` | Owns all truth. Nothing here replicates. |
| **Shared** | `ReplicatedStorage` | Pure, realm-agnostic: types, constants, schemas, math. **Readable by players.** |
| **Client** | `StarterPlayerScripts`, `StarterGui` | Presentation and input. Requests, displays, predicts. Never authoritative. |

The most common structural mistake is putting a *decision* in shared code because both
sides need to know about it. Both sides can share the *formula*; only the server may apply
it. A damage table in `ReplicatedStorage` is fine — the client needs it to show numbers.
A damage *application* reachable from the client is a hole.

## Bootstrapping: services with an explicit lifecycle

Modules that require each other at load time create ordering problems that surface as
intermittent nil errors. The fix is a two-phase lifecycle with a registry:

1. **Construct** — every service is created. No dependencies resolved, no work done.
2. **Init** — dependency-ordered. A service may look up its dependencies and wire internal
   state. It may **not** assume any other service has finished initialising.
3. **Start** — everything is initialised. Connect events, begin loops, spawn work.

```lua
-- ServerScriptService/init.server.luau — the whole server entry point
local Lifecycle = require(ServerPackages["forge-lifecycle"])

local registry = Lifecycle.new()
registry:Add(require(script.Services.RoundService))
registry:Add(require(script.Services.CombatService))
registry:Add(require(script.Services.ProfileService))
registry:Init()   -- dependency order, no cross-service assumptions
registry:Start()  -- everything is live
```

Two properties this buys you: a service can be added without touching a load order list,
and a missing dependency fails at boot with a clear message instead of at 3am under load.

**Corollary for packages:** no require-time side effects, ever. A package that connects an
event on require can't participate in a lifecycle, and breaks outright when its root is
required on both realms. See `skills/forest-author`.

## State replication

Don't hand-roll per-feature remotes for state. Pick one pattern and use it everywhere:

- **Server owns a store.** One authoritative table per concern.
- **Clients get a read-only mirror.** Delta-replicated: send what changed, not the whole
  table.
- **Clients never write to the mirror.** They fire an intent remote; the server mutates the
  store; the delta comes back. The round trip is the point — it's what makes the client
  incapable of lying.

For per-player values that Roblox already replicates (health, walkspeed) use the built-ins.
For anything custom — round phase, scores, inventory — the store pattern beats attributes
and beats a pile of RemoteEvents, because there's exactly one place to look when a value is
wrong.

Attributes are fine for small, cosmetic, single-instance values. They are not a state
system: no batching, no history, no typing.

## Rojo tree

```json
{
  "name": "forge-arena",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Packages": { "$path": "Packages" },
      "Shared":   { "$path": "src/ReplicatedStorage" }
    },
    "ServerScriptService": {
      "Packages": { "$path": "Server/Packages" },
      "Server":   { "$path": "src/ServerScriptService" }
    },
    "StarterPlayer": {
      "StarterPlayerScripts": { "$path": "src/StarterPlayerScripts" }
    }
  }
}
```

Two `Packages` mounts, two manifests, two lockfiles — that's the Forest two-manifest
pattern, and it's how a server-only package is *structurally* prevented from replicating.
See `skills/forest-use`.

## Where does a new system go?

In order:

1. **Would it make sense in a different game?** → a package.
2. **Is it a decision specific to this game?** → `game/`, as data if possible.
3. **Does the client need to know the rule, or only the result?** The rule can be shared;
   applying it cannot.
4. **Can it be pure?** Then make it pure and inject what it needs — that's what makes it
   testable outside Studio (`skills/roblox-testing`).

`game/` should read like wiring and tuning. When a file there grows logic that isn't
specific to this game, that's the signal to promote it into a package.

## Smells

- A module that requires services *and* holds game rules — split it; the rules are testable
  and the service access isn't.
- A `Utils` or `Helpers` module. It's a bag of unrelated things; the parts belong with their
  subjects.
- More than a handful of RemoteEvents per feature. That's a state store trying to be born.
- Client code that computes something the server also computes, with no reconciliation. One
  of them is wrong and nothing will tell you which.
- Anything in `ReplicatedStorage` you'd be unhappy for a player to read. It replicated.
