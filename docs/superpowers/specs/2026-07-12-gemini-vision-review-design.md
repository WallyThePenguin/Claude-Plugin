# Gemini vision-review: second-opinion eyes on rig/grip/animation state

**Date:** 2026-07-12
**Status:** approved in chat (user delegated final calls: 10-frame filmstrip, arm joints read-only in digest)
**Depends on:** the CLIProxyAPI Gemini path (`gemini_image.py` seams), capture tools, the grip system (`ToolFactory`).

## Problem

Grip/animation defects ("the sword points the wrong way", "the swing looks broken") are *visual*
judgments. Claude reasons from stills and its own DataModel reads; the user proposed Gemini as a
second set of eyes — it can weigh many frames at once and the user wants its spatial read tested
against Claude's ("an equal fight"). Gemini, however, sees NOTHING of the workspace by default,
and its native suggestions (rbxlx zips in Downloads, self-authored Lua run in the command bar)
assume Antigravity's file-upload world and are unsafe/unfit for the live-bridge world.

## Decision (the protocol)

Gemini is **eyes, not hands**: it receives the same context Claude reasons from, and it returns a
*described critique as data*. Deterministic plugin/sidecar code — never Gemini — computes and
applies edits through the existing typed tools.

Every review request carries three parts:

### 1. Conventions primer (text)

Fixed preamble so Gemini never guesses Roblox handedness:

```
Motor6D:  Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()
Grip:     AgentEditGrip Motor6D — Part0=RightHand, Part1=Handle,
          C0 ≈ RightGripAttachment.CFrame (hand-local), C1 = tool.Grip
Units:    studs; rotations = Euler XYZ degrees
R15:      character faces -Z; +X = its right; +Y = up
```

### 2. Scene digest (JSON, dumped live from the DataModel over the bridge)

The exact numbers Claude reads — hand attachment frame, Handle size, `Semantic_Grip` frame,
`SemanticFrame` dirs, current `AgentEditGrip` C0/C1 + `tool.Grip`, plus a `derived` plain-English
decode. **Arm joints (RightShoulder/RightElbow/RightWrist C0/C1/Transform) are included
read-only** — full kinematic context for diagnosis — but are NOT in the correction whitelist.

### 3. Image bundle ("video" = many labeled stills)

- 10-frame `capture_animation` filmstrip of the clip under review (neutralLight — backlit rigs
  read as silhouettes, learned live), each frame labeled `t=<sec>` in adjacent text blocks.
- 3 grip stills via `capture_angles` presets front/right/iso, neutralLight, labeled by angle.
- Images ride `image_url` data-URLs in one chat-completions message (the `paint_atlas` shape).

## Output contract (Gemini MUST return only this JSON)

```json
{
  "diagnosis": "plain-English read of what is wrong (may mention arm pose)",
  "observations": [{"label": "t=0.30s", "note": "blade points at ground"}],
  "corrections": [
    {"target": "AgentEditGrip", "property": "C0",
     "op": "rotate_local", "axis": "Z", "deg": -90, "rationale": "..."}
  ],
  "confidence": 0.0,
  "need_more_views": ["right side closeup of the hand"]
}
```

Rules baked into the prompt AND enforced by the validator:

1. **Whitelist**: corrections may target only `AgentEditGrip.C0`, `AgentEditGrip.C1`,
   `tool.Grip`, `Handle.Semantic_Grip.CFrame`. Anything else → correction rejected (diagnosis
   text may still discuss it).
2. **Ops**: `rotate_local` (axis ∈ X/Y/Z, deg), `translate_local` (x/y/z studs),
   `set` (pos + euler_deg). Prefer relative ops.
3. **No guessing**: unreadable views go in `need_more_views`, not into invented numbers.
4. **Advice, not action**: every correction carries a `rationale`; sidecar code validates and
   applies through `ToolFactory.applyGrip`/bridge Luau — Gemini-authored Lua is NEVER executed.

## Components

- `sidecar/gemini_review.py` — mirrors `gemini_image.py` seams (self_describe / in-process
  describe, timeout, atomic behaviors): `build_request(primer, digest, frames, task)`,
  `review(...) -> dict`, `validate(corrections) -> (accepted, rejected)`,
  `to_bridge_edits(accepted) -> Luau via existing grip surfaces`.
- Model: `gemini-3.5-flash-low(high)` (call-time effort suffix — the proven tier mechanism).
- **Probe-first**: `paint_atlas` proves image→image; image→TEXT over this proxy is unverified.
  A 1-image probe gates the build.

## Non-goals

- No mp4/native video (proxy is chat-completions; filmstrip IS the video surrogate).
- No `.rbxlx` export/parse path; the live digest replaces it.
- No Gemini writes of any kind — no Lua, no XML, no file edits.
- Not a replacement for Claude's own read: the first use is a BAKE-OFF (same frames, both
  models, Claude's diagnosis committed first) to measure whether Gemini's eyes add signal.

## Amendment (same day, from the first live run)

- **Digest gained `handle_joints` + `handle_anchored`**: an inventory of EVERY
  joint/weld driving the Handle. Motivated by the live root cause — a stale runtime
  `RightGrip` Weld (a `Humanoid:EquipTool` artifact) silently overriding every
  AgentEditGrip edit. Two joints on one part make CFrame corrections useless; the
  reviewer must be able to see that.
- **Whitelist gained `("RightGrip", "Weld")`, op `delete` — delete-ONLY, and `RightGrip`
  is ONLY deletable** (enforced both ways in `validate_corrections`). The narrow escape
  hatch for exactly that stale-weld class; arms and everything else stay untouchable.
- **Bake-off outcome (2026-07-12):** with the leveled context, Gemini independently found
  the stale weld (confidence 1.0) and proposed valid corrections; its raw pixel-space
  axis reads still erred (blade "backwards" vs the measured forward). Conclusion:
  eyes + instruments (the digest) beats eyes alone for both models; corrections remain
  advice for deterministic code to accept, supersede, or reject.

## Risks

- **Antigravity OAuth volume**: per-iteration vision QA raises call volume on the user's primary
  Google account (ban-risk flagged in repo notes). Mitigation: bake-off first; if the seam goes
  load-bearing, move to a dedicated account or the paid Gemini API.
- **JSON discipline**: flash models may wrap JSON in prose/fences; parser strips fences and
  extracts the outermost object, rejects on schema mismatch (never "best-effort applies").
