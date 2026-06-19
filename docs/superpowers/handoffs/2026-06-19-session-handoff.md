# Session Handoff — 2026-06-19

**For a fresh context window.** Read `HANDOFF.md` (repo root) first for the project + module map; this
file covers the 2026-06-19 session. Memories auto-load via `MEMORY.md` and carry the vision in depth —
especially `studio-agent-north-star`, `studio-agent-asset-creator-vision`, `studio-agent-training-vision`.

## TL;DR
Two features SHIPPED + live-verified — the **multi-image capture rework** and the **`destroy_instance` +
`place_relative`** agent-quality tools (the two obby-session gaps, now closed). Then a long, high-value
**vision/brainstorm** session that crystallized the project's north star and two big agenda items, and
showed that the user's quality exemplars all reduce to a small, reusable set of systems.

## 1. SHIPPED this session (committed on `master`, tree clean)

- **Multi-image viewport capture** (disk-reader). `CaptureService:CaptureScreenshot` writes a full-res
  viewport PNG to `%LOCALAPPDATA%\Roblox\tmp-capture-storage\wob-<PID><n>`; the sidecar now serves
  `GET /captures` (reads the newest `wob` PNGs off disk; token-authed JSON), replacing the whole-window
  PrintWindow grab. Three tools: `capture` (single), `capture_angles` (orbit a target/selection, N
  auto-framed angles), `capture_animation` (**downgraded** — but see the correction below).
  Live-proven: a 4-angle orbit returned 4 distinct full-res framed PNGs. Spec/plan:
  `docs/superpowers/specs/2026-06-18-studio-agent-multi-capture-design.md`,
  `docs/superpowers/plans/2026-06-18-multi-capture.md`. Memory `roblox-plugin-native-screenshot-infeasible`.
- **`destroy_instance`** (`src/Tools/DestroyInstance.luau`) — guarded `Instance:Destroy()` (edit +
  playtest, undoable in edit; refuses `game`/top-level services). **`place_relative`**
  (`src/Tools/Place.luau`) — positions an instance by an ANCHOR-LOCAL direction (front/back/left/right/
  up/down) + distance, so the agent never hand-computes CFrames. Specs: `PlaceSpec` 4/4 (incl. yaw-rotated
  anchor), `RelaySpec` 15/15. Live-verified in a Baseplate. Spec/plan:
  `docs/superpowers/specs/2026-06-18-studio-agent-build-tools-design.md`,
  `docs/superpowers/plans/2026-06-18-build-tools.md`.
  - **GOTCHA learned:** name a Tools/ module anything but a real `Instance` method name. `Destroy.luau`
    failed because `script.Destroy` resolves to the built-in `Instance:Destroy` method (methods shadow
    same-named children on dot-access) → `require` got a function. Renamed to `DestroyInstance`.
- **CORRECTION to the capture_animation downgrade (user):** edit-mode animation playback IS achievable —
  not via `AnimationTrack:Play` (its evaluator doesn't step in edit), but by a plugin DRIVING joints
  frame-by-frame from keyframe data (`KeyframeSequenceProvider:GetKeyframeSequenceAsync` → interpolate →
  set `Motor6D.Transform`), how the Animation Editor / Moon Animator preview in edit. So the filmstrip is
  edit-viable as a follow-up (needs a keyframe pose-engine), NOT playtest-only; that engine is the SAME
  one the animation rigger needs. The shipped tool's "needs playtest" message is now too pessimistic —
  revise when the pose-engine is built.

## 2. The vision crystallized (the big outcome — all in memory)

- **North star (`studio-agent-north-star`):** push the QUALITY CEILING of Roblox games past the generic
  "AI did it" standard. Mechanism = (1) define "good" above the mean via a curated quality corpus +
  rubrics, (2) iterate via the capture loop instead of one-shotting. **Sharper diagnosis:** the gap is
  SYSTEMS, not assets — devs ship a good clip with no system, so it loops and goes stale; Roblox supports
  the systems, they just skip them. **Governing rule: GENERALIZE, don't hardcode** — build data-driven
  systems (interaction matrices, contact-point IK, environmental-state models), not bespoke cases.
- **Asset Creator (`studio-agent-asset-creator-vision`):** a sub-plugin to author ANY visually-iterated
  asset via build→capture→evaluate→refine, per category. Foundation = a **spherical camera-lock rig**
  (CONTAINER→RING→CAMERA: camera locked aiming at the object, agent drives azimuth/elevation/zoom with
  relative commands; the interactive evolution of `capture_angles`). Categories: maps, handheld objects,
  **animation rigger** (R6/R15 now, procedural multi-limb later, blocky placeholders; posing via Motor6D
  works in edit), **VFX = a material-aware impact-reaction system**, mounts (a composition), etc.
  Recurring primitive: **ONE "limb-to-contact-point IK" system** subsumes foot-planting, hands-on-reins/
  stirrups, hands-on-wheel, two-handed grips — declare attachments on the target, IK limbs to them.
- **Training (`studio-agent-training-vision`):** make the agent "perfect at making games" by sampling
  forums / free assets / everything into a per-category quality-reference corpus + rubrics. **User mandate:
  MULTI-session brainstorm (not one) + deep research.** **Key framing to settle first:** you can't
  fine-tune Claude → this is a knowledge/skills system (skills + RAG + rubrics), not weight training.
  Scope includes GAME-SYSTEMS quality, esp. **server-authoritative, lag-compensated, anti-cheat netcode**
  (the real ceiling for multiplayer) and **environmental-state systems** (e.g. darkness must be MODELED
  server-side — no brightness-query API).
- **Convergence insight:** the user's exemplars (locomotion, sword combat + dismemberment, material VFX,
  asymmetric-horror darkness, mounts, racing hand-on-wheel) all reduce to a small set —
  {contact-point IK + blend/gait system + environmental-state + authoritative netcode}, refined via the
  capture-iterate loop. The vision's primitives are bounded and reusable.

## 3. Recommended next steps / open forks
1. **Build:** the **spherical camera-lock rig** — the foundation every Asset Creator category rides on.
   Brainstorm→spec→plan it first.
2. **Or research:** **Training brainstorm SESSION 1** — settle the fine-tuning-vs-knowledge-system framing
   + the corpus/rubric architecture before any data-gathering (use the `deep-research` workflow for
   sampling passes).
3. Still-pending near-term: **sidecar friction** (auto-token + bundle-as-exe), **playtest-context capture**
   (relay/RemoteEvent — also unblocks the rigger's runtime categories), **productize the model connection**
   (replace the personal hecate tunnel — the ship-to-others blocker). Separate product: **Admin Dashboard**.

## 4. Current state
- **Repo:** clean on `master` (latest relevant commits this session: capture `24d150a`→`8c83880`+handoff;
  build-tools `f5a3ffe`→`3a3ade9`). selene 0/0, stylua clean, `rojo build` OK. Installed plugin is the clean
  build (no temp spec block).
- **Studio:** likely still OPEN on a throwaway Baseplate (used for live verification; nothing saved).
- **Infra:** the vision-sidecar test instance (token `spikeverify`) was STARTED then STOPPED this session.
  The hecate model-connection tunnel was NOT used this session — restart `proxy/tunnel.ps1` if needed for
  live agent use. See `studio-agent-model-connection`.

## 5. How to continue in a new session
Just start a fresh session and say "read HANDOFF.md" (or "continue the Studio Agent work"). Memories
auto-load (the full vision is in them); HANDOFF.md → this file gives the narrative. Then pick a fork from §3.
