# SP2c+ proposal — the 2026-07-10 harvest, sequenced

All of this came out of one day of the oracle running live + the user's own research. Design
sessions (brainstorm → spec → plan) still gate the big items; the small items shipped same-day.

## Shipped same-day (no design needed)
- `grip_sane.blade_in_arm_studs` + `clip_self_intersect` arm-centerline sweep (user-caught gap) — `916a58c`, `25a3469`.
- `mesh_persisted` check + melee-suite row + selftest rows (RETRO-proposed; closes the audit's invisible-weapon gap) — `4ce52b0`.
- Audit-rate ops knob `STUDIO_AGENT_AUDIT_EVERY` (running 1-in-2) — `359e8ad`.
- Camera-gizmo boot self-heal — `dee23e2` (persisted-setting flip + live sweep pending bridge).
- NativeRig ground truth corrected to the AnimationConstraint docs — `af5020b`.

## SP2c — WEAPON-AS-JOINT (next design session; the big one)
Research (101-agent, verified): `docs/superpowers/notes/2026-07-10-weapon-joint-research.md`.
Scope sketch:
1. **Joint architecture**: replace the static grip weld with a Motor6D (Part0=RightHand,
   Part1=Handle, joint INSIDE the character; AnimationConstraint dual-path for upgraded rigs).
   The Animator matches poses by CONNECTED PART NAMES → the Handle's name is API surface.
   C0/C1 = static replicated grip channel (must equal authoring-time values); Transform =
   NotReplicated anim channel → weld→joint swap happens SERVER-side at equip.
2. **T-pose-first placement doctrine** (formal invariant, not preference): fit + freeze C0/C1 on
   a NEUTRAL rig, then author clips. Playbooks + grip_tool learn it.
3. **Rest-orientation convention fix**: the measured 1.49-stud blade-in-arm at neutral comes from
   blade-along-fist-up paralleling the forearm. Decide the forward cant (classic tools use the
   RightGripAttachment C0 rotation; 15–25° clears the arm within grip_sane's 35° bound).
4. **Richer frames**: `face_dir` (user's annotated-photo gap), per-object tolerance attributes
   ("the sword's own rules" — max angles/allowed grips live ON the asset, checks read them).
5. **IKControl off-hand**: two-handed grips IK the off hand to a stamped Semantic point
   (IKControl.Target accepts an Attachment; Weapons Kit = first-party prior art).
6. Weapon-channel clips: KeyframeSequences gain the Handle pose channel (flourishes, shoulder
   rests); capture_animation/clip checks follow.

## SP2d — RUN-MODE VERIFICATION TIER (small, high value)
`StudioTestService:ExecuteRunModeAsync` (verified real) = real Animator/physics, NO player spawn,
automatic server view. Implement the declared PLAY_ONLY twin stubs (`played_arc_of`,
`track_priority_audit`, `stable_over`) in run mode; add `play run` / `playtest_start {mode:"run"}`.
Caveats: changes revert on Stop (observation tier only); PlayBridge supervisors assume play mode.
Middle rung of the doctrine: edit scrub → run-mode twin → full playtest.

## SP2e — SSE PUSH CHANNEL (transport verified)
`HttpService:CreateWebStreamClient` (RawStream | SSE; Opened/MessageReceived/Error/Closed + Send)
is the real engine API — the pasted `ConnectAsync` WebSocket API does NOT exist (doc-verified).
Down = SSE command stream (kills the 0.25s poll); up = existing POSTs. Step 1 = a plugin-context
pcall probe (docs are silent on plugin/edit availability + beta flags).

## Ops/infra follow-ups
- **Docs-grounding channel**: clone Roblox/creator-docs + machine-readable API-dump diff vs
  PropertyCatalog per Studio update (twice-vindicated today: refuted `ConnectAsync`, confirmed
  `IsRunMode`). Sidecar `docs_search`/`api_diff` local tools ride the SDK loop's MCP path.
- **VirtualInput** for playtest driving (fixes the observed "couldn't walk to the dummy" UNVERIFIED).
- AnimationConstraint-NATIVE authoring stack (docs Phase 2; forced migration ~end 2026).
- MLSession / DataPredict in-Luau ML — future.
- MECHANIC hygiene: explicit-path staging + single [mechanic] prefix (filed in tooling-issues).
- Stale-ChangeHistory root fix (filed; hot-reload clears it interim).
