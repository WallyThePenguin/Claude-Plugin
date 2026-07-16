# 2026-07-16 — Forge Arena kickoff: P1 shipped, P2 mid-conveyor

The zero-touch flagship run began (spec: `docs/superpowers/specs/2026-07-16-zero-touch-flagship-run-design.md`; metric ledger: `factory/intervention-ledger.json`). This note is written LIVE per the new handoff discipline — dated files, not the root journal.

## P1 — core loop skeleton: COMPLETE, evidence-gated

- **Place2** (placeId 71518658263588), verified fresh via bridge probe before any edit.
- Built: `workspace.ForgeArena` (120×120 walled arena), `ServerStorage.ForgeEnemyTemplate` (placeholder humanoid; P3 replaces via make_npc), `ReplicatedStorage.ForgeConfig`, `ServerScriptService.ForgeRoundLoop` (intermission → waves 4/6/8 → victory → restart). Both scripts via compile-checked `edit_script`.
- **Evidence:** RUN-mode unmanned playtest — THREE full cycles in 40s, every wave spawned/cleared, VICTORY twice-plus, zero errors (`playtest_logs` full tail, cursor 30).
- **Banked:** `606cd8b` (old Place1 wave-survival + NEON GAUNTLET banks archived under `game/archive/` — game/ is now the Forge Arena bank, fresh manifest), `2db84f4` (game_pull P1; **TestAutoKill correctly flagged as a test symbol** — the factory gate blocks it from shipping), `39bdebd` (run spec + ledger + brainstorm transcript).
- Ledger: 2 entries, both bootstrap (`direction`, `platform-gate`). **Zero touches during the build.**

## P2 — armory, weapon 1 (ember falchion): mid-conveyor

- Reference: `assets/reference/forge-falchion-ref.jpeg` (10s Gemini gen, textbook single-object white-bg; eyeballed per GIGO doctrine). Pre-whitened variant `-ref-clean.jpeg` (bg >232 → 255, 903k px) for threshold bg-removal.
- **Stalls hit + fixes (all agent-side, zero user touches):**
  1. **Proxy tunnel DOWN** (first Gemini call refused) → raised it myself: `proxy/tunnel.ps1` in a background shell (SSH key-auth, non-interactive). Lesson: **tunnel-up belongs in run preflight** alongside sidecar start.
  2. **Stale plugin generation** (Studio opened while sidecar was down → `edit_script` "unknown tool") → `studio-agent.ps1 reload`. Lesson: **reload is step zero when Studio booted sidecar-less.**
  3. **birefnet alloc 500** (VRAM) → pre-whitened ref + `bg_removal='threshold'` (safe here because WE authored the white bg; the gray-backdrop slab doctrine doesn't apply).
  4. **NVIDIA starvation** — the headline stall: 7.1/8.2GB VRAM resident (Studio + desktop tenants incl. Parsec), both 1024 AND 512 runs blew the 1200s client timeout at 82-91% util (512 norm is 87s — a 15-20x crawl), and both finished jobs were DISCARDED into dead sockets. → **killed the server, relaunched on the iGPU lane** (`STUDIO_AGENT_TRELLIS_VK_DEVICES=""` → ggml picks the 33GB AMD UMA device), 512 regen in flight at write time. Filed as tooling-issue #25 (starvation detection + result salvage). Doctrine: **starved-NVIDIA signature = wall >> norm at high util; the iGPU lane is the designed fallback — use it without ceremony.**
- Next on the conveyor: rig_weapon cleanup (`--canon long-y --target-studs 5 --smooth 5 --uv planar --uv-sides 2 --bake-ao`) → relief paint_atlas → EditableMesh import (contract mapped: `/assets/mesh?file=&textured=1`, 1-based faces; **importer Luau to be COMMITTED as a real tool this phase** — it was session-scratch three times, a residue-rule violation) → save_mesh+confirm_mesh → make_tool/stamp_frame/grip_tool → swing clip via retarget (UAL2 Sword_Regular family) → bind_hitbox.
- NOTE: `sidecar/blender_scripts/rig_weapon.py` carries the rapier session's UNCOMMITTED `--remesh` flag + box/cyl UV modes (additive, default-off — usable as escalation if hole-counts are bad).

## P2 weapon 1 — COMPLETE through persistence (late session)

**The ForgeFalchion landed end-to-end**: ref (10s, eyeballed) → TRELLIS 1024 birefnet (150.4s) → rig_weapon cleanup (19,499 tris, extents 1.86×0.32×5.0, 923+385 holes closed, planar 2-sided UVs aspect 5.37, AO 1024²) → relief paint (10.1s — runic steel + molten edge channel + bronze guard, keeper first roll) → **`import_mesh` first production use** (11,171 verts, uvs+normals complete, atlas session-backed) → in-arena capture eyeballed → save_mesh: mesh `rbxassetid://103390730043911` + texture `rbxassetid://72913711270849`, moderation pending (confirm_mesh later). REMAINING: grip chain (edge-dir via render-candidates), swing clip, hitbox.

**THE TRELLIS SAGA, FINAL DIAGNOSIS (supersedes the mid-session theories):** every "birefnet alloc" today was one of two causes — (a) NVIDIA VRAM tenancy (the user's Palworld 4.9GB + NVIDIA Overlay 2.3GB) leaving no 2.4GB contiguous buffer, or (b) the job landing on the **AMD iGPU**, whose driver caps single allocations below birefnet's 2.4GB request no matter the 33GB pool. The iGPU also runs flow stages 15-100x slow (wedged >45min at stage 3) — **falsified as a practical lane for generation**. A transient NVIDIA-ICD dropout right after the game exit produced one AMD-only enumeration; and the `[trellis] using VulkanN` log line is the ONLY trustworthy device signal — pin with BOTH `STUDIO_AGENT_TRELLIS_VK_DEVICES=0` and an explicit `GGML_VK_VISIBLE_DEVICES=0` export, and verify the device line before trusting a run (the server also has a native `--gpu N` flag, banked for belt-and-suspenders). Client timeouts ORPHAN finished server compute (no result cache) — tooling-issue #25.

**Studio-restart doctrine reconfirmed twice today:** a fresh Studio boot runs a stale plugin generation even with the sidecar up — `reload` is step zero after ANY Studio (re)start; the tell is "unknown tool/command kind".

## Standing user errands (unchanged)

Move Gemini OAuth off the primary Google account (ban risk, paint-path load-bearing); memtrace stays behind its tripwire (SP4 trigger conditions in the flagship spec).
