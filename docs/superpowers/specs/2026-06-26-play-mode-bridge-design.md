# Play-mode dev bridge (autonomous playtests) — design (2026-06-26)

**Status:** approved in brainstorming (research-grounded — `StudioTestService` confirmed live), ready for an
implementation plan.

**Goal:** Let the agent start, drive, observe, and stop a Studio **playtest** entirely from the shell —
no human keypress, no desktop control — so runtime behavior (the default character walking while a Tool's
LocalScript animates, hit detection, NPCs) can be self-verified. Closes the gap that the edit-only dev
bridge leaves (it can preview in edit but not enter Play).

## 0. Why this is possible (research, 2026-06-26; verified live)

`StudioTestService` (PluginSecurity) lets a plugin start/stop a playtest programmatically — confirmed
present in the user's Studio (`ExecutePlayModeAsync`/`ExecuteRunModeAsync`/`EndTest`/`GetTestArgs`/
`ExecuteMultiplayerTestAsync` all resolve to functions; `UserInputService:CreateVirtualInput()` works).
`RunService:Play()` does nothing (a dead end). So Play entry needs NO F5 and NO screen automation.

- **`StudioTestService:ExecutePlayModeAsync(args): Variant`** — starts a solo **Play** test session and
  **YIELDS** the calling thread until the session ends; returns whatever `EndTest` passed back.
- **`StudioTestService:EndTest(value)`** — ends the active test (from the test's server DM), returning
  `value` to the yielded `ExecutePlayModeAsync`.
- **`VirtualInput`** (`UserInputService:CreateVirtualInput()`) — simulated mouse/keyboard, a fallback for
  actions the Humanoid API can't express (e.g. a real click).

## 1. Architecture

### 1a. Entry/exit (edit side)
A new sidecar **`/play` channel** (separate from `/agent`, so the dev-bridge command loop and the play
loop never compete). The EDIT-side bridge gains a `play start` handler: it `task.spawn`s
`StudioTestService:ExecutePlayModeAsync(args)` (so the `start` command returns immediately) and sets a
`playing = true` flag; it SKIPS `/play` polling while `playing` so it can't grab the play loop's commands;
when `ExecutePlayModeAsync` returns (the test ended) it clears `playing` and posts the test's final result.

### 1b. Driving during the test (play side)
When the plugin loads inside the test session, a **`PlayBridge`** starts and polls `/play/pending`,
dispatching:
- **`eval <luau>`** — run Luau in the play DM (drive: `Humanoid:EquipTool(tool)` / `Humanoid:Move(dir)` /
  `Tool:Activate()`, or read state) and return the serialized result.
- **`capture`** — `CaptureService:CaptureScreenshot` in the play CLIENT context; the sidecar reads the PNG
  from disk (the same path the edit `capture` uses) and the shell fetches it via `/captures`.
- **`act equip|walk|stop|activate [args]`** — one-word sugar that expands to the matching `eval` snippet
  (equip the first Backpack Tool; start/stop walking forward; activate the equipped Tool).
- **`stop`** — call `StudioTestService:EndTest(...)` from the play SERVER DM to end the session.

### 1c. Server vs client inside the test
Play Solo runs a SERVER copy (HttpService works — the Relay relies on this) and a CLIENT copy (owns the
local character + the viewport). The character is client-owned, and `CaptureScreenshot` is client-side, so
those actions must run on the CLIENT. The baseline: the **CLIENT copy hosts the `PlayBridge` poll loop**
(it owns what we drive). If the client copy cannot reach the localhost sidecar over HTTP (a Studio
Play-Solo quirk — Build Verification #1), fall back to **the SERVER copy polling + relaying client actions
to a tiny client handler over a `StudioAgentPlayRelay` RemoteEvent** (the same server/client split the
existing `Relay` uses, extended for play commands). `EndTest` is always invoked on the SERVER DM.

### 1d. Shell
`scripts/studio-agent.ps1 play <start|stop|eval|capture|act> [arg]` → the sidecar `/play` channel; `play`
returns the command result (or, for `capture`, saves the PNG like the existing `capture` subcommand).

## 2. Build Verifications (the FIRST tasks — real unknowns, never assume)

Each runs behind an automatic `EndTest` timeout so a test can never hang the editor:
1. **Plugin-in-test + polling:** does the plugin load inside an `ExecutePlayModeAsync` session, and can
   the CLIENT copy (else the SERVER copy) reach `127.0.0.1:8389` over HTTP? Resolves §1c (client-polls vs
   server-relay).
2. **DM topology:** is it separate server/client copies (Relay's `serverplay`/`clientplay`) or a single
   combined DM? Resolves where the poll loop + `EndTest` live.
3. **Capture path:** does `CaptureScreenshot` during the test write to the same
   `%LOCALAPPDATA%\Roblox\tmp-capture-storage` file the sidecar's `/captures` reads.

The verification harness: a `play start` whose args tell the in-test `PlayBridge` to (a) try an HTTP GET to
the sidecar and POST the outcome, (b) report `Relay.mode()` + `IsServer`/`IsClient`, (c) trigger a capture,
then `EndTest` after a few seconds (or on a `stop`).

## 3. Components & files

### New
- **`src/PlayBridge.luau`** — the in-test poll loop + dispatch (`eval`/`capture`/`act`/`stop`), the
  client/server role logic, and the `RemoteEvent` relay fallback. Pure helpers (the `act`→`eval` snippet
  expansion; the command classification) unit-tested in `PlayBridgeSpec`.
- **`src/PlayBridgeSpec.luau`** — pure tests (act-verb expansion, command parsing).
- **`sidecar/test_bridge.py`** additions — `/play` Store methods (a second single-slot channel + result).

### Changed
- **`sidecar/bridge.py`** — `Store` gains a `/play` command slot + result map (mirroring the `/agent`
  + `/reload` channels).
- **`sidecar/server.py`** — `POST /play`, `GET /play/pending`, `POST /play/result`, `GET /play/result?id=N`.
- **`src/Main.luau`** — start the edit-side `play start` handler (the `playing` flag + `ExecutePlayModeAsync`
  spawn) for the EDIT generation; start `PlayBridge` for the `serverplay`/`clientplay` generations.
- **`src/init.server.luau` / `src/DevBridge.luau`** — the edit-side `/play` poll (the `play start` handler)
  lives alongside the existing dev-bridge loop, lifecycle-aware (so a hot-reload swaps it too). (Edit-side
  play handling belongs to the reloadable `Main`; the bootstrap is untouched.)
- **`scripts/studio-agent.ps1`** — a `play` subcommand.
- **`src/SystemPrompt.luau`** — a short note that the agent can self-playtest (so the build agent uses it).

### Reused
- `StudioTestService` (entry/exit); `Relay` (the `serverplay`/`clientplay` mode detection + the RemoteEvent
  pattern); `CaptureCore` + the sidecar `/captures` disk-read (capture in play); `Tools.dispatch`/run_luau
  (the `eval` body); the hot-reload (iterate the PlayBridge with no restart).

## 4. Data flow (a self-driven playtest)

```
shell: studio-agent.ps1 play start
  POST /play {cmd:"start"}  -> edit bridge: playing=true; task.spawn(ExecutePlayModeAsync(args))
                               (Studio enters Play Solo; edit DM suspends)
  [in test] PlayBridge starts, polls /play/pending
shell: studio-agent.ps1 play act equip      -> PlayBridge: Humanoid:EquipTool(firstBackpackTool)
shell: studio-agent.ps1 play capture         -> PlayBridge(client): CaptureScreenshot; shell GET /captures
shell: studio-agent.ps1 play act walk        -> PlayBridge: Humanoid:Move(forward)  ... capture ...
shell: studio-agent.ps1 play act activate    -> PlayBridge: Tool:Activate()         ... capture ...
shell: studio-agent.ps1 play stop            -> PlayBridge(server): EndTest()
                               (test ends; ExecutePlayModeAsync returns; edit bridge: playing=false; posts result)
```

## 5. Error handling / edge cases

- **Never hang the editor:** every test path has a deadline — the in-test PlayBridge auto-`EndTest`s after
  an idle timeout (no command for N seconds) so a dropped shell or crash can't strand Studio in Play.
- **Total dispatch:** `eval`/`act`/`capture` are pcall-wrapped → `(content, isError)`; a failure returns an
  error string, never throws.
- **Already playing / not playing:** `play start` while `playing` → a friendly "already in a test"; a play
  command while NOT in a test → "no active test — run play start first".
- **Client can't poll (Verification #1 = false):** fall back to server-polls + RemoteEvent relay (§1c).
- **Edit/play channel isolation:** the edit bridge skips `/play` while `playing`; the play bridge only
  exists during a test — so exactly one consumer of `/play/pending` at a time.
- **Hot-reload during play:** out of scope — reload between tests (the supervisor is edit-side); a test is
  a fixed snapshot.

## 6. Testing & acceptance

- **Static/spec:** `stylua`/`selene` 0/0; `rojo build`; `PlayBridgeSpec` (act-verb expansion + parsing);
  Python `/play` Store tests.
- **Live gate (closes #2's runtime check, by the agent):** `play start` → confirm Studio entered Play via a
  `play capture` (the running game) → `play act equip` + capture (held pose, blade up) → `play act walk` +
  capture (legs walk, head level, arm holds) → `play act activate` + capture (the swing) → `play stop`.
  This is the first time the agent confirms a runtime gate with no human in the loop.

## 7. Scope & non-goals

**In (v1):** the `/play` sidecar channel, `PlayBridge` (`eval`/`capture`/`act`/`stop`), the
`StudioTestService` start/stop with the `playing` flag, the 3 build verifications, the `studio-agent.ps1
play` subcommand, the specs + the live gate.

**Out (deferred):**
- **Multiplayer tests** (`ExecuteMultiplayerTestAsync`, up to 8 clients) — single-player Play Solo first.
- **Rich `VirtualInput` scripting** beyond the Humanoid-API `act` verbs — add only if an action can't be
  expressed via the Humanoid/Tool API.
- **Hot-reloading code mid-test** — reload between tests.
- **Recording/video** — single screenshots via the existing capture path.

## 8. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build …` (selene 0/0) + the Python suites. A plugin code change now applies
via `studio-agent.ps1 reload` (no Studio restart) — except a bootstrap/HotReload change. Execute with
**superpowers:subagent-driven-development**; commit per task; don't push. The PlayBridge itself is
iterated with hot-reload + a `play start`/`play stop` round-trip.
