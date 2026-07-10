# SP1 — Agent SDK loop swap (headless path) — design

Date: 2026-07-10. Status: designed, approved in-session, pending user spec review.

## 1. Goal & context

Replace the hand-rolled model transport + agentic loop in `sidecar/agent_loop.py` with the official **Claude Agent SDK (Python)** running on the user's Claude subscription (`claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN`), for the **headless path only** (factory/forever). The in-Studio interactive Luau loop (`AgentLoop.luau`/`Subagent.luau`/`Compactor.luau`) is untouched and migrates in a later sub-project.

Why now:
- The proxy-era machinery (leading-message preamble because CLIProxyAPI strips `system`, manual retry ladder, `unknown provider` cold-start dance, keep-K image pruning, 8192 `max_tokens` quirk) exists only because there was no SDK on this path. The SDK provides system prompts, retries, prompt caching, context compaction, and native web tools.
- Subscription use through Anthropic's own SDK/CLI is the sanctioned first-party path (vs. the third-party-harness pattern Anthropic blocks).
- It is the foundation for the rest of the roadmap: **SP2 Roblox Oracle** (symbolic assertion layer; red-team notes in `docs/superpowers/notes/2026-07-10-roblox-oracle-redteam.md`), **SP3 external 3D generation (TRELLIS)**, **SP4 memtrace attach**, **SP5 learnings-retrieval upgrade**. Skills, subagents, session fork/resume, and per-run cost reporting become available (not wired in SP1).

Decisions already made by the user: deep adoption; headless-only scope; **approach A** (seam swap behind a flag); memtrace = MECHANIC-stage-only attach (it is proprietary-EULA freeware, not modifiable; code-graph only); Gemini demoted to narrow optional tool pending SP2.

## 2. Architecture

One new module: `sidecar/sdk_loop.py` exporting `SdkLoopRunner` with the **exact** public surface of `LoopRunner`:

- `start(prompt, max_iterations=None, model=None, local_tools=None) -> run_id` — non-blocking (daemon thread hosting an asyncio loop), raises `LoopError` on bad input / already running.
- `status() -> dict` — thread-safe deep copy: `state ∈ {idle, running, done, error}`, `result`, `error`, `iteration`, `toolCalls`, `events`, `recent[]`, `startedAt`, `model` (+ new: `usage` per-run token/cost).

Selection: `server.py` picks the runner once at startup from env `STUDIO_AGENT_LOOP=sdk|legacy` (default `legacy` until T2 passes). `factory.py`, `forever.py`, `mechanic.py`, the charter, sentinels, staging, HTTP fencing — all unchanged.

Per `start()`:
1. Same `describe` handshake over the shared `BridgeCaller` (single-slot discipline preserved by construction).
2. `describe.instructions` → SDK `system_prompt` (real system prompt; preamble hack retired on this path). If the T0 spike shows a Windows argv limit for large system prompts, fall back to instructions-as-first-user-message (existing pattern, different reason).
3. Bridge tool schemas → **dynamically generated** in-process MCP server (`studio`): one handler per tool, each dispatching `{"kind":"tool","tool":name,"input":...,"raw":True}` through `BridgeCaller.call` (240s timeout; `dispatched:true/false` timeout guidance text preserved verbatim; `fix_luau_empty_objects` applied at the boundary). Image content blocks pass through as base64 `image` blocks (SDK-supported), so the model still sees captures. `web_search`/`web_fetch` bridge schemas are excluded; Claude Code's native WebSearch/WebFetch are allowed instead (retires `pause_turn` handling).
4. `local_tools` (MECHANIC) → merged into the same server, dispatched sidecar-side; contract `{"schemas": [...], "dispatch": (name, args) -> (text, is_error)}` unchanged. memtrace attaches as a second MCP server **only** when `local_tools` is present (mechanic sessions), behind `STUDIO_AGENT_MEMTRACE=1`.
5. Fresh SDK session per run (no resume): VERIFY stays a memoryless skeptic; BUILD/VERIFY isolation preserved.
6. `ClaudeAgentOptions`: `permission_mode="bypassPermissions"`; native tools (Read/Write/Edit/Bash/Glob/Grep/…) **disallowed** in SP1 — blast radius identical to today; `allowed_tools` = the generated `mcp__studio__*` names (+ WebSearch/WebFetch); `max_turns = max_iterations`; `model` from `describe.model` with the existing fallback-chain behavior on rate-limit errors; `setting_sources=[]` (no skills/CLAUDE.md leakage in SP1); `cwd` = repo root.
7. Auth: `CLAUDE_CODE_OAUTH_TOKEN` required in the sidecar env; `ANTHROPIC_API_KEY` **scrubbed** from the child env (it silently overrides subscription and bills per-token). `ANTHROPIC_BASE_URL` → CLIProxyAPI documented as break-glass fallback only.
8. Wall clock: `WALL_CLOCK_CAP` (45 min) enforced with an asyncio deadline; on breach, kill the CLI subprocess **tree** (Windows), set `state=error`. Every exit path lands a terminal state — a wedged `running` permanently 409s the stack (existing invariant).

Tool-name note: generated tools surface as `mcp__studio__<name>`. The system prompt gets a one-line mapping note so instructions referencing bare names (`capture`, `run_luau`) resolve; T0 verifies the model calls them correctly.

## 3. Contracts preserved (from the 2026-07-10 architecture audit)

1. Exact `start/status` call surface; no `stop()` assumed by callers.
2. Polling-terminal semantics; terminal state always reached.
3. `result` = final assistant text **verbatim** — the sentinel contract (`FACTORY_BUILD_JSON`, `FACTORY_VERIFY_JSON`, `FACTORY_RETRO_JSON`, `FACTORY_MECHANIC_JSON`, `FACTORY_PROPOSALS_JSON`; last occurrence wins, trailing prose tolerated). The runner accumulates assistant text and returns the final message's text unmodified.
4. `max_iterations` honored as a hard cap (SDK `max_turns` + a runner-side assistant-turn counter as belt-and-braces; budgets: BUILD 45 / VERIFY 36 / RETRO 5 / AUTHOR 6 / MECHANIC 30).
5. Wall-clock bound below the outer backstops (`factory LOOP_WAIT_CAP` 50 min, forever caps).
6. `local_tools` injection contract byte-compatible.
7. Single-slot bridge discipline via the shared `BridgeCaller`; `_START_LOCK`/busy fencing untouched.
8. Prompt-as-full-configuration; fresh conversation per `start()`.
9. Descriptive error strings via `status().error` (feeds `BLOCKED:` reasons → RETRO).
10. Immediate reentrancy after terminal state.
11. JSONL transcripts: SDK message stream mirrored into `sidecar/loops/loop-<ts>-<id>.jsonl` in the existing event shapes (RETRO transcript-tail and ps1 poller keep working); plus per-run `usage`.

## 4. Retired / kept / unlocked

**Retired on the headless path:** `ModelClient` (urllib transport), `send_with_retry`/`is_transient` ladder (incl. `unknown provider` cold-start), the `with_preamble` system hack, keep-K image pruning (SDK owns history; see risk R2), `pause_turn` resend, `max_tokens` 8192 quirk.

**Kept:** `BridgeCaller` + single-slot queue + fencing; `fix_luau_empty_objects`; `describe` handshake; factory-side prompt assembly (learned-lessons block, playbooks, oracle briefs — unchanged); charter enforcement in `factory.py`/`forever.py`; JSONL transcripts; `MODEL_FALLBACKS` behavior (re-implemented over SDK errors); the legacy `LoopRunner` behind the flag.

**Unlocked (not wired in SP1):** skills via `setting_sources` (quality-pack delivery per training spec §9 — revise that spec's preamble clause when adopted), programmatic subagents, session resume/fork, cost telemetry, native Read/Edit/Bash for MECHANIC (deliberately deferred: the curated `local_tools` + auto-revert discipline is what the self-improvement charter hangs on).

**Supersedes:** `2026-06-16-studio-agent-cliproxyapi-design.md` §2 ("exclusively through a local CLIProxyAPI instance") — for the headless path only. Plugin-internal model calls (`evaluate` judge, `dispatch_subagents`/`dispatch_writers` children) and the interactive Luau loop remain on CLIProxyAPI until later sub-projects.

## 5. Error handling

- CLI spawn/auth failures → `state=error` with a descriptive message (e.g. `sdk auth: CLAUDE_CODE_OAUTH_TOKEN missing/invalid`).
- Subscription usage-window exhaustion → `state=error`, non-retryable (same policy as today's `"out of extra usage"`); forever's cycle accounting and compute backstop handle back-off.
- Transient API errors → SDK-internal retries; anything surfacing is terminal for the run and descriptive.
- Wall-clock breach → subprocess-tree kill → `state=error "(wall clock cap)"`.
- Missing sentinel in `result` → existing factory coercion (BLOCKED / UNVERIFIED) — unchanged, by design.
- Crash guard: total `try/except` around the async runner mirrors `_run`'s guarantee — never a wedged `running`.

## 6. Testing plan

- **T0 spike (standalone script, nothing wired):** subscription auth works and does not bill an API key; `system_prompt` delivery at real instructions size (Windows argv check); an image-returning SDK tool round-trips visibly; `max_turns` vs iteration semantics calibrated; sentinel passthrough verbatim; `mcp__studio__*` naming resolves from instructions.
- **T1 units (`sidecar/test_sdk_loop.py`):** fake-bridge patterns from `test_agent_loop.py` — start/status lifecycle, `LoopError` on double-start, tool dispatch (bridge + local_tools), `[]→{}` fix, timeout guidance text, wall-clock kill, terminal-state guarantee, transcript JSONL shape, sentinel-bearing `result`.
- **T2 integration A/B:** one full factory cycle (BUILD→GATE→VERIFY→STAGE) on a proven family with `STUDIO_AGENT_LOOP=sdk` in a **fresh Baseplate** (per test-session doctrine); compare vs a legacy cycle: staging entry schema identical, sentinels parsed, images present in transcript, token/cost per cycle recorded for the economics comparison (risk R2).
- **T3 soak:** 2–3 forever cycles on `sdk`; watch for wedged states, usage-window behavior, transcript integrity, RETRO/MECHANIC/AUTHOR stages functioning.

Success = T2 parity (same charter outcomes, sentinels parsed, evidence images seen) + rollback flag verified + economics measured and acceptable.

## 7. Rollout / rollback

Flag default `legacy` → flip to `sdk` after T2; legacy loop retained through the SP2 era minimum. Env setup documented in HANDOFF: `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` in sidecar env; ensure `ANTHROPIC_API_KEY` absent; optional `STUDIO_AGENT_MEMTRACE=1`. Rollback = flip flag; no data migration in either direction (transcripts/staging formats unchanged).

## 8. Risks ledger (all with detection points before forever depends on them)

- **R1 Windows argv limit** for large system prompts — T0; fallback = leading-user-message delivery.
- **R2 image-token economics** without keep-K pruning — T2 A/B measures; mitigations: lower `imagesKept` at source, downscaled captures; root-cause fix is SP2 (oracle replaces most measurement captures).
- **R3 `max_turns` semantics** — T0 calibration + runner-side counter.
- **R4 sentinel verbatim-ness** — T1 unit before integration.
- **R5 tool-name prefixing confusion** — T0; system-prompt mapping note.

## 9. Non-goals (SP1)

Interactive in-Studio loop migration; skills/quality-pack loading; Gemini tools; TRELLIS; memtrace beyond the mechanic-stage attach flag; native-tool MECHANIC; SDK-native orchestration (factory/forever stay the outer brain — approach C explicitly rejected: the charter stays code, not model discretion).
