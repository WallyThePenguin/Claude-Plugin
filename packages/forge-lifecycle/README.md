# forge-lifecycle

A service registry with two explicit lifecycle phases and dependency-ordered boot.

## Install

```sh
forest i @<scope>/forge-lifecycle
```

## The problem it solves

Modules that require each other at load time create ordering problems that surface as
intermittent `nil` errors — the kind that reproduce once a week under load and never in
Studio. Separating *exists* from *wired* from *running* makes the ordering explicit and
checkable:

| Phase | Guarantee |
|---|---|
| `Add` | The service exists. No dependencies resolved, no work done. |
| `Init` | Dependency-ordered. A service may look up its dependencies. It may **not** assume any other service has finished initialising. |
| `Start` | Everything is initialised. Connect events, begin loops, spawn work. |

What that buys: a service can be added without editing a load-order list, and a missing or
circular dependency fails **loudly at boot with a named path** instead of silently at 3am.

## Why not `sleitnick/knit`?

Knit (mirrored, 1.7.0) does this — but bundles its own networking and component system,
both of which this workspace replaces with `forge-net` and its own composition. This package
is the ordering, alone, with zero dependencies.

That makes it the weakest "write it ourselves" call in the workspace, and it's held to a
budget: **if it grows past ~200 lines, take Knit instead.**

## Usage

```lua
local Lifecycle = require(ServerPackages["forge-lifecycle"])

local registry = Lifecycle.new()

registry:Add({
    Name = "Profile",
    Start = function(self)
        Players.PlayerAdded:Connect(loadProfile)
    end,
})

registry:Add({
    Name = "Round",
    Requires = { "Profile" },      -- resolved before this service's Init runs
    Init = function(self, reg)
        self.profiles = reg:Get("Profile")
    end,
    Start = function(self)
        self:beginLoop()
    end,
})

print(registry:Order())   -- {"Profile", "Round"} — log this; it is your boot order
registry:Init()
registry:Start()
```

Order is deterministic: services with no constraint between them resolve in **insertion
order**, not hash order, so a boot log is comparable run to run.

## API

`Lifecycle.new()` returns a registry.

| Method | Behaviour |
|---|---|
| `Add(service)` | Returns the service. Errors on a duplicate or empty `Name`, or after `Init`. |
| `Init()` | Resolves order, then calls each `Init(registry)`. Errors on a second call. |
| `Start()` | Calls each `Start()` in the same order. Errors if `Init` hasn't run. |
| `Get(name)` | Errors if absent — a typo should stop the boot, not return `nil`. |
| `Find(name)` | Returns `nil` if absent. |
| `Order()` | The resolved order, as a copy. Works before `Init`. |
| `Phase()` | `"added"` / `"initialised"` / `"started"`. |

A service is any table with a `Name`. `Requires`, `Init` and `Start` are all optional — a
pure data service is fine.

### Errors name the problem

```
dependency cycle: A -> B -> A
Round requires unknown service Porfile
```

Both at boot, both naming the path. That is the entire value proposition.

## License

MIT
