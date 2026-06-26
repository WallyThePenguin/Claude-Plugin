# Dev-bridge hot-reload (full plugin, manual trigger) — design (2026-06-26)

**Status:** approved in brainstorming, ready for an implementation plan.

**Goal:** Apply plugin code changes to the *running* Studio plugin in ~1 second via a manual `reload`
command, with NO Studio restart. Eliminates the build→restart cycle that currently gates every plugin
code change (the friction that stalled the use-animations dogfood). Full-plugin reload: the bridge
transport, tool/engine code, and UI all reload; only a tiny stable bootstrap is exempt.

## 0. Why — the constraint and the trick

Roblox Studio loads plugin code only at startup, and Luau `require` caches a ModuleScript by its
**instance**. So rebuilding `StudioAgent.rbxm` does nothing until Studio restarts and re-requires fresh
instances. The trick: at runtime, **clone the plugin's module tree into a fresh container, write the new
source onto the clones, and `require` the clone** — because the clones are new instances, `require` runs
them fresh (transitively: a fresh `Tools` pulls a fresh `AnimationClip`, etc.). Then swap the running
generation for the fresh one. The sidecar (a local process with filesystem access) supplies the new
source from `src/` on demand.

## 1. Architecture

### 1a. Stable bootstrap vs reloadable Main
- **`src/init.server.luau`** shrinks to a thin, STABLE **bootstrap** (the only file that still needs a
  restart when changed — kept tiny and rarely touched). It: creates the persistent toolbar + button +
  dock widget (Studio dedupes these by name/id, so they survive reloads), holds a `runtime` table, runs
  generation 1, and starts the **supervisor loop**.
- **`src/Main.luau`** (NEW) holds everything `init.server` does today *after* the toolbar/widget: build
  `deps`, compute the relay mode, start the DevBridge command loop, mount the UI, wire the button/widget
  connections. Exposes `Main.run(ctx) -> Lifecycle`.

### 1b. Lifecycle (clean teardown so reload doesn't double up)
Each generation owns a `Lifecycle` = `{ cancelled: boolean, connections: { RBXScriptConnection },
add(conn), cancel() }`. `Main.run` registers its bridge loop (which checks `lifecycle.cancelled` each
tick and exits when a new generation starts), its event connections, and its UI mount in the lifecycle.
`lifecycle:cancel()` sets the flag, disconnects all tracked connections, and clears the widget mount.
Reload cancels the *previous* lifecycle BEFORE running the fresh `Main`, so there are never duplicate
poll loops, button handlers, or mounted panels.

### 1c. Supervisor loop + sidecar reload channel
- `& scripts/studio-agent.ps1 reload` → `POST /reload` on the sidecar, which sets a `reload_requested`
  flag (with an id). It does NOT use the command queue (`/agent/*`), so reloads never compete with
  tool/luau/prompt commands.
- The **supervisor loop** (in the bootstrap, never reloaded) polls `GET /reload/pending`. When a reload
  is pending, the sidecar returns `{ requested = true, id, sources }` where `sources` is a
  `{ relativePath = luauSource }` map read FRESH from `src/**/*.luau` at request time; the flag clears.
  The supervisor runs the reload, then `POST /reload/result { id, ok, error? }` so the shell sees the
  outcome.

### 1d. The reload engine (`src/HotReload.luau`, stable — required by the bootstrap)
`HotReload.reload(script, runtime, ctx, sources) -> (ok, err)`:
1. Create a fresh `Folder` `container`.
2. `Clone` each child of `script` (the plugin's modules: `Main`, `Tools`, `AnimationClip`, `UI`, …) into
   `container`, preserving the subtree (so the clones' relative `require`s resolve inside the clone).
3. For each `(relativePath, source)` EXCEPT `init.server.luau`: resolve the path to an instance in
   `container` (creating a `ModuleScript`/`Folder` if the path is new — so added files reload too) and set
   its `.Source = source`.
4. `pcall(require, container.Main)`.
   - **On success:** `runtime.lifecycle:cancel()` (tear down the old generation) → `container.Main.run(ctx)`
     (returns the new lifecycle, stored in `runtime.lifecycle`) → destroy the prior `runtime.container`,
     set `runtime.container = container`. Return `(true, nil)`.
   - **On error:** destroy the new `container`, leave the old generation running, return `(false, err)`.
     A broken reload NEVER bricks the plugin — worst case is "fix the code and reload again".

`HotReload` also exposes the pure, unit-tested helpers:
- `HotReload.resolvePath(container, relativePath) -> (parentInstance, childName, isModule)` — maps a Rojo
  relative path to its place in the tree (`"AnimationClip.luau"` → child `AnimationClip` of the root;
  `"Tools/Animate.luau"` → child `Animate` of `Tools`; `"Tools/init.luau"` → the `Tools` ModuleScript
  itself; folder segments without an `init.luau` → `Folder`).
- `HotReload.newLifecycle() -> Lifecycle`.

### 1e. Generation 1
The bootstrap runs gen 1 by requiring the REAL `script.Main` directly (no clone/sync needed — the source
is already current) and storing the returned lifecycle. Subsequent reloads use the clone path.

## 2. Components & files

### New
- **`src/Main.luau`** — the reloadable entry: `Main.run(ctx) -> Lifecycle` (build deps, relay mode,
  start the lifecycle-aware DevBridge loop, mount UI, wire connections).
- **`src/HotReload.luau`** — `reload` engine + `resolvePath` + `newLifecycle` (stable; required by the
  bootstrap, so its own changes need a restart — part of the stable core).
- **`src/HotReloadSpec.luau`** — pure tests for `resolvePath` (existing + new + `init.luau` + nested
  folder cases) and lifecycle bookkeeping (cancel disconnects all + sets the flag).

### Changed
- **`src/init.server.luau`** — thin bootstrap: persistent toolbar/button/widget, `runtime` table, the
  supervisor loop (poll `/reload/pending` → `HotReload.reload`), gen-1 run.
- **`src/DevBridge.luau`** — `DevBridge.start(deps, lifecycle)`: the poll loop checks
  `lifecycle.cancelled` each tick and exits when set (so a reload stops the old loop); registers nothing
  else. Existing command handling (tool/luau/prompt) unchanged.
- **`src/Config.luau`** — add `getReloadPollInterval()` (a slightly slower poll than the command loop is
  fine) and the `/reload*` URL helpers if URL-building lives there; else the supervisor builds them from
  `getSidecarUrl()`.
- **`sidecar/bridge.py`** — `Store` gains a `reload` flag + id (`request_reload()`, `take_reload()`,
  `put_reload_result()`, `get_reload_result()`).
- **`sidecar/server.py`** — `POST /reload` (set the flag → `{id}`), `GET /reload/pending` (return
  `{requested, id, sources}` reading `src/**/*.luau` from disk relative to the repo root, and clear the
  flag), `POST /reload/result`, `GET /reload/result?id=N`.
- **`scripts/studio-agent.ps1`** — a `reload` subcommand: `POST /reload` → poll `/reload/result?id` →
  print `ok` / the error.

### Reused
- The HttpService GET/POST helper pattern from `DevBridge.luau`; `Config:getSidecarUrl()`; the existing
  toolbar/widget creation; the `Tools`/`AnimationClip`/etc. modules (unchanged — they just get reloaded).

## 3. Data flow (a reload)

```
shell: studio-agent.ps1 reload
  -> POST /reload                         (sidecar sets reload_requested, returns {id})
supervisor loop (bootstrap):
  GET /reload/pending  -> {requested:true, id, sources:{path:source}}  (sidecar reads src/ from disk)
  HotReload.reload(script, runtime, ctx, sources):
     clone children of `script` -> container
     apply sources to clones (create missing), skip init.server.luau
     require(container.Main)  (fresh modules)
     runtime.lifecycle:cancel()    (old loop exits, old connections off, old UI unmounted)
     container.Main.run(ctx)  -> new lifecycle  (new loop, new UI, new connections)
     destroy old container; runtime.container = container
  POST /reload/result {id, ok=true}
shell: prints "reload ok"
```

## 4. Error handling / edge cases

- **Bad new code** (require/run throws): caught; new container destroyed; OLD generation keeps running;
  error returned to the shell. No brick, no forced restart.
- **Reload mid-command:** the supervisor is a separate loop/endpoint from the command loop. If a tool
  command is in flight, the old bridge loop finishes it, then sees `cancelled` and exits; the new loop
  picks up the next command. The single-slot queue means no command is duplicated.
- **New files:** `resolvePath` creates a `ModuleScript` (or `Folder`) for a path with no existing
  instance, so adding a module reloads without a restart.
- **Bootstrap/HotReload changes:** these are the stable core; changing them still needs ONE restart (the
  accepted boundary — they're small and rarely touched).
- **Edit-only + localhost-only:** the supervisor + reload no-op outside edit and only talk to 127.0.0.1,
  matching the existing DevBridge trust boundary. Never active in a shipped game.
- **Transient state:** Conversation + TaskList reset on reload (rebuilt fresh); Memory/Skills/Learnings/
  Sessions are plugin-setting-backed, so their DATA survives (only the wrapper objects are rebuilt).

## 5. Testing & acceptance

- **Static/spec:** `stylua`/`selene` 0/0; `rojo build`; `HotReloadSpec` covers `resolvePath` (5+ cases)
  + lifecycle cancel. Python: a `test_bridge.py` case for the reload flag/result; a `server.py` reload
  endpoint smoke (source map read from a temp tree).
- **One-time enabling restart:** building this is a plugin change → ONE final `build.ps1` + restart to
  load the new bootstrap. After that, no more.
- **Live proof (the gate):** change a tool's output string in `src/`, run `studio-agent.ps1 reload`
  (no restart), then call that tool via the bridge and confirm the NEW string — and that a second reload
  still works (no duplicate loop: the command still returns exactly one result). Then immediately use it
  to finish roadmap #2 (the swing-fire + grip fixes) with zero restarts.

## 6. Scope & non-goals

**In:** the bootstrap/Main split, `HotReload` (clone+resource+require+swap, `resolvePath`, lifecycle),
the lifecycle-aware DevBridge loop, the sidecar `/reload*` endpoints + source reading, the
`studio-agent.ps1 reload` subcommand, the specs + the live proof + the enabling restart.

**Out (deferred):**
- **Auto-reload on file change** (a sidecar file-watcher) — manual `reload` is the chosen trigger.
- **Hot-reloading the bootstrap/HotReload itself** — they're the stable core (restart on change).
- **Cross-session conversation persistence through a reload** — Conversation/TaskList reset is acceptable
  for the dev loop (the persisted data already survives via plugin settings).
- **Reloading in play mode** — edit-only, like the bridge today.

## 7. Build / verify loop

`stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene 0/0) +
the Python suites. Plugin change → `build.ps1` (+ the ONE enabling restart). Execute with
**superpowers:subagent-driven-development**; commit per task; don't push. After this lands, every later
code change uses `reload` instead of a restart.
