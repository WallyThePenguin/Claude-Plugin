# 2026-07-25 — Serializer strict numeric validation (the engine-drift decision, closed)

Focused hardening session in worktree `sleepy-pasteur-a3e87d`. Input: the 2026-07-25 handoff note
asking for a DECISION — after the live probe confirmed Roblox's geometric constructors
(Vector3/Vector2/Color3/UDim/UDim2/CFrame `.new`) no longer throw on non-number args (numeric
strings coerce, other garbage/missing args become 0), should `Decode.luau` strictly pre-validate
numeric fields, or keep passing engine coercion through?

## The decision: strict pre-validation (nil-on-malformed restored engine-side)

`{"__t":"Vector3","x":"a","y":2,"z":3}` was decoding to `Vector3(0,2,3)` and landing in real
properties via set_property/create_instance. Three reasons carried the decision:

1. **The consumer is an autonomous agent.** A loud refusal it can immediately correct beats a
   plausible-but-wrong value it can only catch through expensive capture verification. Silent
   wrong values are the worst failure class for the zero-touch metric.
2. **Doctrine uniformity.** BrickColor's echo-verification (`aa48c12`) already established
   "nil, never silently wrong" at this seam. Geometric tags now obey the same rule.
3. **Own the contract.** The old nil-on-malformed behavior was borrowed from the engine's
   throwing constructors; the engine drifted once and silently changed our observable contract
   with zero code changes. Validation in our code is immune to further drift.

Numeric strings ("1") refuse DELIBERATELY: the encoder only emits real JSON numbers, so a string
field always means a malformed producer; accepting it would pin decode to the engine's unowned
coercion grammar. This is taught in SystemPrompt + both write-tool descriptions and by the
refusal message itself.

## What changed (commit `46acc6a`, stacked on `aa48c12`)

- **`src/Decode.luau`** — `allNumbers` validates `type(field)=="number"` for every numeric field
  of the six geometric tags before the constructor runs; any mismatch (missing fields included)
  decodes the whole tag to nil. `try()` demoted to totality backstop (ENGINE NOTE updated).
  **Behavior delta beyond the letter of the ask:** a missing/non-table CFrame `c` now decodes to
  nil instead of the old identity-CFrame fallback — that fallback could silently teleport a part
  to the world origin, the exact bug class this commit kills.
- **`src/Serialize.luau`** — frozen comment block updated byte-identically (machine-diffed, 38
  lines) with the new STRICT NUMERIC FIELDS bullet.
- **`src/Tools/ValueGuard.luau` (NEW, shared like RegionGuard)** — `nilDecodeRefusal(raw, decoded)`
  distinguishes unresolved REFERENCE tags (Instance/EnumItem/BrickColor → "value reference did
  not resolve") from malformed GEOMETRIC tags ("value malformed: every numeric field of a Vector3
  must be a JSON number (a string like \"1\" or a missing field is refused, never coerced)").
- **`src/Tools/Properties.luau`** — set_property refuses via ValueGuard (replaces its local
  isUnresolvableReference); tool description teaches the numeric-fields rule.
- **`src/Tools/Create.luau`** — create_instance routes nil-decodes to `failed[]` BEFORE
  assignment. This closes a real hole: a nil-ASSIGNABLE property (Adornee, ObjectValue.Value)
  would previously have silently applied the nil and reported "applied".
- **`src/SerializeSpec.luau`** — the 7 malformed-* samples flipped back to `isNil` (they had been
  flipped to pin engine coercion in `aa48c12` while the decision was pending), plus 3 new pins:
  `malformed-udim2-partial`, `malformed-cframe-missing`, `malformed-cframe-nontable`. 44 samples.
- **`src/SystemPrompt.luau`** — one terse clause at both value-encoding sites: "Numeric fields
  must be JSON numbers, not strings (\"1\" is refused, never coerced)."

## Verification (live, via studio-agent.ps1 — the temp-main-tree-deploy drill)

Worktree gotcha honored: the sidecar serves src/ from the MAIN checkout, so the changed files
were temp-copied there (src/ pre-checked clean), reloaded, verified, then `git checkout -- src/`
restored + reloaded back. Results:

- SerializeSpec **44/44** in-Studio.
- create_instance mixed payload → `applied=["Anchored","Size"]`, `failed=["Position"]` (x="a").
- set_property refused x="a" AND x="1" with the teaching message; accepted a good Vector3 with
  faithful echo; refused `{"__t":"CFrame"}` (no origin teleport).
- Regression: BrickColor typo ("Brigt red") still refuses via the reference branch.
- stylua/selene clean on the changed lines (repo-wide CRLF-vs-LF noise is environmental —
  working tree is autocrlf CRLF; check formatting against LF-normalized copies).

## State after this session

- Branch `claude/sleepy-pasteur-a3e87d` = master + `aa48c12` (BrickColor, fast-forwarded from
  `claude/practical-dhawan-673d96`) + `46acc6a` (this work) + the docs commit — merged to
  `master` (fast-forward). Studio reloaded onto merged HEAD, spec re-smoked.
- The `practical-dhawan-673d96` worktree/branch is now fully merged → safe to
  `git worktree remove` + `git branch -d` once no session is using it.
- Auto-memory `studio-agent-worktree-hotreload-gotcha` updated: the drift is GUARDED as of
  `46acc6a` — don't re-litigate passthrough without new evidence.
