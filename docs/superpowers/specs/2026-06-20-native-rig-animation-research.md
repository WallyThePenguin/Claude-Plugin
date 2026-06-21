# Native Roblox Rigging + Animation in Luau — deep-research findings

**Date:** 2026-06-20
**Status:** research complete (facts gathered + adversarially verified). **No code yet** — this is the
fact base for planning slices B–E of the rig editor. Do NOT build from this until it is turned into a plan.
**Serves:** Asset Creator sub-project #2 ("full animation application"), slices B (IK), C (drag posing),
D (keyframe/animation engine), E (Evaluate vs the Locomotion rubric).
**Method:** the `deep-research` skill / workflow (run `wf_66374fd5-8ba`): 6 search angles, 27 sources fetched,
118 claims extracted, **25 verified by 3-vote adversarial verification** (need 2/3 refutes to kill) →
**21 confirmed, 4 killed**. Primary sources are create.roblox.com / the Roblox/creator-docs GitHub mirror
and DevForum. Earlier run was started + stopped with nothing saved; this is the clean re-run.
**Reads on:** the rig-workbench design (`2026-06-20-studio-agent-rig-workbench-design.md`) and the
session handoff (`docs/superpowers/handoffs/2026-06-20-rig-animation-session-handoff.md` §3 open questions).

---

## 0. TL;DR — what changed vs the handoff's assumptions

The research **confirms all three live-verified walls** and hands us a native path around each:

| Wall (live-verified) | Native workaround the research found | Confidence |
|---|---|---|
| `InsertService:LoadAsset` of the official rig → "Asset is not trusted" | **`Players:CreateHumanoidModelFromDescriptionAsync(desc, rigType)`** — returns the native Motor6D Humanoid rig (R6 or R15 by `rigType`), needs **no asset id / no userId** (a default `Instance.new("HumanoidDescription")` works). `Security: None`. | **high** (3-0) |
| No `RigBuilderService` | Irrelevant — the model-from-description API above is the real programmatic rig source; we never needed a "Rig Builder service". | **high** |
| `AnimationTrack.TimePosition` doesn't advance in edit | **`Animator:StepAnimations(deltaTime)`** — documented as **"for use in the command bar or by plugins only"**; it increments `TimePosition` of all playing tracks and applies the offsets to the model. This is the method the **official Animation Editor uses** to play in edit. | **high** (3-0) |

Two findings reshape the roadmap, and one is genuinely unresolved:

1. **Slice D (animation engine) gets a NATIVE evaluator.** The handoff hypothesized we'd hand-roll a
   per-frame Motor6D.Transform stepper that interpolates keyframe data ourselves. We don't have to: build a
   real `KeyframeSequence`, register it locally (no upload), `Animator:LoadAnimation` it, and drive playback
   in edit with `Animator:StepAnimations(dt)`. We get Roblox's own blending/interpolation/easing for free.
   (Caveat: the Animator *overrides* `Motor6D.Transform` while stepping — see §4 — so static posing and
   animated playback are two modes that must not fight.)
2. **Slice B (IK) should NOT be built on `IKControl`.** `IKControl` is a continuous per-frame *runtime*
   solver with **no static `Solve()`** path; its edit-mode reliability is **unresolved** (every "works in
   edit / can be driven programmatically" neighbor claim was *killed* in verification). Recommendation: build
   our own CCD/FABRIK solver that writes `Motor6D.Transform` (the channel we already drive live in edit).
3. **Export (publish a KeyframeSequence as an Animation asset) is UNRESOLVED** — the research contradicted
   itself here (see §5). Treat silent programmatic animation upload as **not proven**; plan for a manual /
   Open-Cloud fallback and live-verify.

---

## 1. Rig creation from a plugin, in code (no trusted asset)

### 1.1 The headline: `Players:CreateHumanoidModelFromDescriptionAsync` ✅ (high, 3-0)
- **`Players:CreateHumanoidModelFromDescriptionAsync(description, rigType, assetTypeVerification?)`** returns
  a `Model` with the **native Motor6D Humanoid skeleton**, "R6 or R15 **as specified by `rigType`**"
  (`Enum.HumanoidRigType.R6` / `.R15`). It needs **no userId and no asset** — a default
  `Instance.new("HumanoidDescription")` is a valid argument. This **avoids `InsertService:LoadAsset`
  entirely**, so the "Asset is not trusted for this place" gate never applies.
- **`Players:CreateHumanoidModelFromUserIdAsync(userId)`** mirrors a real user's avatar and **preserves**
  whether that avatar is R6 or R15, but **cannot force** a rig type. To choose the type off a real avatar,
  combine **`GetHumanoidDescriptionFromUserId(userId)`** → tweak → `CreateHumanoidModelFromDescriptionAsync(desc, rigType)`.
- **The non-`Async` forms are deprecated** — use the `Async` variants.
- Sources: create.roblox.com `Players` (CreateHumanoidModelFromDescription / …FromUserId),
  DevForum "can I use CreateHumanoidModelFromUserId to create a R6 model" (3824079).

### 1.2 Security + edit-mode reality ✅ confirmed, ⚠️ one caveat to live-test (high, 3-0 / 2-1)
- `CreateHumanoidModelFromDescription`, `CreateHumanoidModelFromUserId`, `GetHumanoidDescriptionFromUserId`,
  `GetHumanoidDescriptionFromOutfitId` **all carry `Security: None` and `Yields: Yes`** — **none are
  security-blocked for a plugin**. There is no PluginSecurity barrier here.
- **The real constraint is that they yield / hit Roblox web backends.** `…FromUserId` / `…FromOutfitId`
  clearly need network (they read a real avatar). `…FromDescription` with a hand-built description is the
  most likely to work fully offline-in-edit, but the docs mark it `Yields` too.
- The **Oct 2025 `assetTypeVerification` change** (DevForum 3982903) is **server-runtime type-checking only**
  and is **distinct from the InsertService trust gate** — a staff reply says "during Studio Edit time, I
  don't believe anything changes" (hedged). Pass `Enum.AssetTypeVerification.Default`/`.Always` per the new
  signature; it does not gate edit-time use.
- **⚠️ LIVE-TEST #1 (highest priority):** does `CreateHumanoidModelFromDescriptionAsync(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)`
  actually return a rig **in EDIT mode at PluginSecurity over our HttpService environment**? The staff quote
  is hedged and "Yields/web" is exactly the kind of thing that behaves differently in edit. This single test
  decides whether `spawn_rig` gets a true native mode or stays on the placeholder.

### 1.3 Paths the research ruled OUT or left as gaps
- **`Humanoid:BuildRigFromAttachments()` — KILLED (1-2).** It is *not* a reliable code-only way to wire a
  Motor6D skeleton from loose parts for a plugin; don't design on it.
- **Building the skeleton from scratch with exact part names/sizes + numeric `C0`/`C1`** — **NOT covered by
  this research** (explicit gap). Our existing `RigTemplates.luau` already builds a correct-by-construction
  *blocky placeholder* (C0/C1 computed from chosen part positions), which remains the fallback. If we later
  want a byte-faithful R15, mine the cited structure sources (Parihsz gist `e200bc669b…`, roblox.fandom
  `Character/Structure`, the R15 shoulder/neck DevForum threads) — but **1.1 likely makes a from-scratch
  numeric rebuild unnecessary**.
- **Publishing/owning a rig so LoadAsset becomes trusted** — not separately resolved; mooted by 1.1 (we no
  longer need LoadAsset to get a native rig).

---

## 2. Rig structure (Motor6D skeleton, C0/C1, R6 vs R15)

- A rig is a tree of **`Motor6D`** joints. Each Motor6D has **`Part0`**, **`Part1`**, **`C0`** (joint frame
  in Part0 space), **`C1`** (joint frame in Part1 space), and **`Transform`** (the animation offset). The
  world relation it enforces: `Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()`. **`C0`/`C1` =
  rig setup** (where the joint lives); **`Transform` = the animation/pose channel** (already confirmed to
  apply **live in edit** — this is the foundation we built slice A on).
- **R6** Motor6Ds live in the **Torso** and are named **Neck, Left Shoulder, Right Shoulder, Left Hip,
  Right Hip** (+ **RootJoint** HumanoidRootPart→Torso). 6 visible parts.
- **R15** is a deeper tree (each named Motor6D parented under its Part0): **Root** (HumanoidRootPart→
  LowerTorso), **Waist** (LowerTorso→UpperTorso), **Neck** (UpperTorso→Head), and per side **Shoulder →
  Elbow → Wrist** (UpperTorso→UpperArm→LowerArm→Hand) and **Hip → Knee → Ankle** (LowerTorso→UpperLeg→
  LowerLeg→Foot). 15 parts.
- **`Humanoid.RigType`** (`Enum.HumanoidRigType.R6`/`.R15`) selects which skeleton; `CreateHumanoidModelFromDescriptionAsync`'s
  `rigType` arg sets it. **R15 may be MeshParts or blocky** ("Block Rig") — both share the identical Motor6D
  joint names/structure, so our rig-agnostic `get_rig`/`pose_joint` work on either.
- **House note:** the research did **not** return the exact numeric C0/C1 matrices (explicit gap). We don't
  need them if we spawn via 1.1 (the API gives correct centers) and pose via `Transform` (slice A already
  does). Numeric C0/C1 only matters for a from-scratch custom rig — deferred.

> Verification note: the structure claims above are partly from secondary/forum sources (roblox.fandom,
> DevForum C0/C1 threads, the Parihsz gist) rather than the strongest 3-0 primary-doc claims. The
> joint-name/structure facts are well-corroborated and match slice A's live R6 read, but treat any *numeric*
> offset as unverified until seen on a live rig.

---

## 3. Animation authoring pipeline in Luau (build a clip in code)

### 3.1 Legacy `KeyframeSequence` tree ✅ (high, 3-0)
Build an animation as **pure Instance parenting** — no upload needed to *construct* it:
- **`KeyframeSequence`** — the container; holds all `Keyframe` children + `Loop` and `Priority`.
- **`Keyframe`** — "holds the **Poses applied to joints** in a Model at a given point of time"; its position
  on the timeline is **`Keyframe.Time`** (seconds). The **highest `Keyframe.Time` = the clip length.**
- **`Pose`** — holds **the `CFrame` applied to the `Motor6D`** for one joint at that keyframe. Pose name =
  the joint/part name. **`Keyframe:AddPose()`** parents a pose; **`Pose:AddSubPose()`** nests child-joint
  poses (the R15 tree); **`RemovePose`** sets `Parent = nil`. (`KeyframeSequence:AddKeyframe()`/
  `GetKeyframes()`/`RemoveKeyframe()` manage the keyframe list.)
- So: **walk the rig's Motor6Ds → snapshot each `Transform` as a `Pose.CFrame` → group into a `Keyframe` at
  time t → parent keyframes under a `KeyframeSequence`.** That is a programmatic clip built from joint poses.

### 3.2 Modern curve API: `CurveAnimation` ✅ (high, 3-0)
- **`CurveAnimation`** is a subclass of **`AnimationClip`** (sibling to `KeyframeSequence`). Instead of
  discrete poses it stores **per-channel curves** in a **Folder-per-joint hierarchy matching the Motor6D/Bone
  tree**: each joint Folder holds a **`Vector3Curve` "Position"** + a **`EulerRotationCurve`/`RotationCurve`
  "Rotation"**. This is the newer, higher-fidelity representation (smooth interpolation, Bone support).
- **Decision input:** `KeyframeSequence` is simpler and is what `RegisterKeyframeSequence` / the legacy
  preview path consumes (§4). Start slice D on `KeyframeSequence`; keep `CurveAnimation` as a fidelity
  upgrade once the loop works.

---

## 4. Edit-mode posing + playback (the core mechanism)

### 4.1 Posing — `Motor6D.Transform` (already live-verified) ✅
Confirmed again: setting `Motor6D.Transform` poses the rig **live in edit**. This is slice A's foundation and
stays the primitive for static posing.

### 4.2 Playback — `Animator:StepAnimations(deltaTime)` ✅ (high, 3-0) — **resolves handoff §3.2**
- `Animator`/`AnimationTrack` playback **does not auto-evaluate in edit** (why `TimePosition` looked frozen).
- The documented edit-mode driver is **`Animator:StepAnimations(deltaTime)`** — "**Increments the
  `AnimationTrack.TimePosition` of all playing AnimationTracks … and applies the offsets to the model. For
  use in the command bar or by plugins only.**" This is how the **official Animation Editor** plays in edit.
- **So the native edit-mode filmstrip is:** register a `KeyframeSequence` locally (§4.3) → set
  `Animation.AnimationId` to the temp id → `Animator:LoadAnimation(anim)` → `track:Play()` → each frame call
  `Animator:StepAnimations(dt)` (e.g. off a Heartbeat or a manual loop) → the rig animates in edit, the
  camera rig captures it. **We do NOT have to reimplement keyframe interpolation** — the native evaluator runs.

### 4.3 Local preview without uploading ✅ (high, 3-0)
- **`KeyframeSequenceProvider:RegisterKeyframeSequence(ks)`** → a **temporary content hash id** usable as an
  `AnimationId`; **`RegisterActiveKeyframeSequence(ks)`** → an **`active://` URL**. Both are **Studio-only**
  ("cannot be used outside of Studio") — perfect for an edit-mode preview that never touches the cloud.

### 4.4 ⚠️ The Animator-vs-Transform conflict (gotcha to design around)
Cited DevForum threads flag two real hazards: **"AnimatorStepAnimations isn't changing Motor6DTransform"**
(106576) and **"Animator is overriding the Transform property of Motor6D welds while no animation is
playing"** (2444010). Implication: **an Animator that exists/steps will OVERRIDE manual `Motor6D.Transform`
writes.** So static posing (slice A/B/C, manual Transform) and animated playback (slice D, Animator+
StepAnimations) are **two modes that must not run at once.** Design rule for slice D: only have an `Animator`
present + a track loaded **during playback**; for static posing have **no playing track** (or no Animator).
**LIVE-TEST #2:** confirm `StepAnimations` actually moves the rig in *our* edit context, and that
removing/stopping the track returns full control to manual `Transform`.

---

## 5. Saving / exporting animations programmatically — ⚠️ UNRESOLVED (flag)

**This is the one place the research contradicted itself — reporting it honestly:**
- The synthesized finding (medium confidence) says **`AssetService:CreateAssetAsync`** "can only be used in
  locally loaded plugins and uploads assets **without prompting**" but supports **only Model / Plugin / Mesh
  (EditableMesh) / Image (EditableImage)** — **NOT Animation/KeyframeSequence** — so a clip can't be silently
  published this way.
- **BUT** the stricter claim *"CreateAssetAsync supports only four AssetType values … does NOT support
  Animation"* was **KILLED 0-3** in verification (all three verifiers refuted it). So the "only four types"
  framing is **not trustworthy** — the supported-type list may be broader (or changing).
- Net: **whether a plugin can silently publish a usable online Animation asset is NOT established.** Treat it
  as **not proven**.
- Community signal that a path may exist: DevForum **"AnimationPublisher — update and publish animations
  easily"** (4263713) and **"uploading animations in bulk … with the console"** (4170801) — i.e. people *do*
  publish animations programmatically, plausibly via **Open Cloud / the web upload endpoint** rather than
  `AssetService:CreateAssetAsync`. Also noted: a thread reports **CreateAssetAsync/CreateAssetVersionAsync
  "are broken"** (4527300) — the API is in flux.
- **Decision:** for slice D, **edit-mode preview is fully native and free** (§4 — no upload needed). **Export
  to a shippable AnimationId is a separate, lower-priority step with no proven silent path.** Plan a
  **manual-save fallback** (hand the user the registered KeyframeSequence to upload, or open the upload
  dialog) and **investigate Open Cloud animation upload** as the automated route.
- **OPEN QUESTION (carry):** any programmatic path to publish a `KeyframeSequence` as an online `Animation`
  asset without a manual dialog? (Open Cloud? a current `AssetService` type list?) — **LIVE-TEST #3.**

---

## 6. IK — don't build slice B on `IKControl`

- **`IKControl`** is "a child of the rig's **Humanoid or AnimationController**" and is a **continuous
  per-frame runtime solver** — "**at each frame the IKControl will try to satisfy it**" — with **no static
  `Solve()`** method. Props: **`Type`** (Position/Rotation/LookAt/FullBody), **`EndEffector`**, **`ChainRoot`**,
  **`Target`**, **`Pole`** (optional), `Weight`, `Enabled`. (confirmed: it's runtime/per-frame, 2-1.)
- **Edit-mode reliability is UNRESOLVED — three IKControl neighbor claims were KILLED:**
  - "IKControl can be created/modified programmatically (usable from a plugin)" — **KILLED 1-2.**
  - "IKControl requires a Humanoid/AnimationController parent → bound to the non-evaluating Animator in edit" — **KILLED 1-2.**
  - (Only "it's a continuous per-frame runtime solver" survived, 2-1.)
  The verifiers couldn't agree it works for static grab-and-place in pure edit.
- **`AnimationConstraint`** is mentioned as the lighter alternative for constraint-style posing, but the
  research did not deeply characterize its edit behavior.
- **Recommendation for slice B:** **implement our own IK** (CCD or FABRIK) that **writes `Motor6D.Transform`
  directly** down the chain — the channel we have already proven works live in edit and that we fully
  control. This sidesteps IKControl's runtime/edit uncertainty and the Animator-override hazard (§4.4),
  fits the "AI sets the target, solver poses the joints" model, and reuses slice A's posing primitive.
- **OPEN QUESTION (carry):** can `IKControl`/`AnimationConstraint` produce a *reliable static pose in pure
  edit*? If a quick live spike says yes, it could replace a hand-rolled solver — but **plan B = our own
  solver** until proven.

---

## 7. How the built-in Animation Editor & Moon Animator 2 work (which APIs)

- **Official Animation Editor:** selects a rig by its **Motor6D tree**, poses by writing **`Motor6D.Transform`**,
  stores the timeline as a **`KeyframeSequence`** (Keyframe/Pose), previews in edit via
  **`Animator:StepAnimations(dt)`** on a locally **registered** KeyframeSequence, and exports through Roblox's
  **upload** path (the "Publish to Roblox" save → an AnimationId). Every primitive in §§3–5 is exactly what
  it uses — so cloning its core loop is well-trodden ground.
- **Moon Animator 2:** the research only secured the "getting started" overview (476330) — it confirms the
  same Motor6D-posing model and a far richer timeline/easing UI, but its **internal APIs/export were not
  characterized** (gap). Its differentiators (multi-rig scenes, camera tracks, advanced easing) are UX, not
  new engine primitives — so not a blocker for our pipeline.

---

## 8. Recommended architecture for the AI rig+animation plugin (all in EDIT mode)

Built on the verified primitives, slotted into our existing modules. Each step flags **native / manual /
unresolved**.

| Step | Mechanism | Status | Notes |
|---|---|---|---|
| **Spawn a native rig** | `Players:CreateHumanoidModelFromDescriptionAsync(Instance.new("HumanoidDescription"), rigType)` | **native, pending LIVE-TEST #1** | Adds a "native" mode to `spawn_rig`; **placeholder `RigTemplates` stays the fallback** if the API doesn't yield in our edit/plugin context. R6/R15 by arg. |
| **Read + visualize skeleton** | slice A `get_rig` (Motor6D walk + gizmos) | **native, DONE** | Rig-agnostic — already works on any Motor6D rig incl. a real R15. |
| **Static pose joints** | slice A `pose_joint` → `Motor6D.Transform` | **native, DONE (live)** | The base for B/C. **No Animator present during static posing** (§4.4). |
| **IK grab-and-place (slice B)** | **our own CCD/FABRIK** writing `Motor6D.Transform` | **native, build ourselves** | **Do NOT depend on `IKControl`** (edit reliability unresolved, §6). AI sets target → solver poses chain. |
| **Drag posing (slice C)** | PluginMouse + handles → `Motor6D.Transform` (agent IK target + user drag) | native | Banked in `studio-agent-asset-creator-vision`; composes with B. |
| **Build a clip from poses (slice D)** | snapshot `Motor6D.Transform` per joint → `Pose.CFrame` → `Keyframe` (`Time`) → `KeyframeSequence` | **native** | Start legacy `KeyframeSequence`; `CurveAnimation` is a later fidelity upgrade (§3.2). |
| **Preview the clip in edit (slice D)** | `KeyframeSequenceProvider:RegisterKeyframeSequence` → `AnimationId` → `Animator:LoadAnimation` → `track:Play()` → loop **`Animator:StepAnimations(dt)`** | **native, pending LIVE-TEST #2** | Roblox's own evaluator runs — no hand-rolled interpolation. Compose with the **camera rig** to revive `capture_animation` as an edit-mode filmstrip. **Add/step the Animator only during playback.** |
| **Export to a shippable AnimationId** | `AssetService:CreateAssetAsync`? / Open Cloud? / manual upload | **UNRESOLVED, LIVE-TEST #3** | No proven silent path (§5). Ship **manual/Open-Cloud fallback**; preview works without it. |
| **Evaluate (slice E)** | capture the previewed animation → grade vs the **Locomotion rubric** (`use_rubric locomotion`, RubricStore shipped) | native (our stack) | Closes capture→evaluate→refine. Depends on D's preview + the camera rig. |

**Sequencing implication:** D's **preview** path is fully native and unblocks E **without** solving export.
So the build order can be **B → C → D-preview → E**, with **D-export** parked behind LIVE-TEST #3 / Open Cloud
research. The single most decisive unknown is **LIVE-TEST #1** (native spawn in edit) — run it first.

---

## 9. Live-verification checklist (the "yields/web in edit" risks the docs can't answer)

Static docs can't tell us how these behave at **PluginSecurity in EDIT mode** over our HttpService setup —
the user must run these in Studio (fresh Baseplate, hecate tunnel), highest-value first:

1. **#1 Native spawn:** `CreateHumanoidModelFromDescriptionAsync(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)`
   in edit at PluginSecurity — does it return a rig, or yield/error on web access? (Decides `spawn_rig` native mode.)
2. **#2 Edit playback:** register a `KeyframeSequence` → `Animator:LoadAnimation` → `track:Play()` →
   `StepAnimations(dt)` — does the rig actually animate in edit? Does stopping/removing the track hand
   control back to manual `Motor6D.Transform`? (The §4.4 conflict.)
3. **#3 Export:** can a plugin publish a `KeyframeSequence`→`Animation` silently (current `AssetService`
   type list / Open Cloud), or is a manual dialog unavoidable?
4. **(spike)** Does `IKControl` (or `AnimationConstraint`) hold a reliable **static** pose in pure edit? If
   yes, reconsider §6; if no/finicky, our own solver stands.

---

## 10. Coverage gaps (what this research did NOT settle)

- **Exact R15/R6 numeric `C0`/`C1` offsets + part sizes** for a from-scratch rig (mooted by §1.1 unless
  LIVE-TEST #1 fails; mine the Parihsz gist / fandom Character/Structure if needed).
- **Moon Animator 2 internals / export APIs** (only the getting-started overview secured).
- **`AnimationConstraint` edit-mode behavior** (named as the IK alternative but not characterized).
- **The export contradiction** (§5) — the single biggest open factual question; resolve via LIVE-TEST #3 +
  an Open Cloud docs pass.

---

## 11. Source ledger (verified)

**Primary (create.roblox.com / creator-docs GitHub):** `Players` (CreateHumanoidModelFromDescription /
…FromUserId), `Humanoid`, `KeyframeSequence`, `Keyframe`, `CurveAnimation`, `Animator`,
`KeyframeSequenceProvider`, `AssetService`, `IKControl`, `animation/inverse-kinematics.md`.
**DevForum:** HumanoidDescription assetTypeVerification update (3982903), R6-from-userId (3824079),
Motor6D C0/C1 (195820, 1449174, 2154350), R15 shoulder/neck (164625), StepAnimations-not-changing-Transform
(106576), Animator-overriding-Transform (2444010), bulk animation upload via console (4170801),
CreateAssetAsync broken (4527300), AnimationPublisher (4263713), IKControl beta (1999010), Moon Animator 2
getting started (476330).
**Secondary/community:** roblox.fandom Character/Structure, Parihsz Motor6D gist (`e200bc669b…`), MaidenlessUsr/RigConverter.

**Verification scoreboard:** 25 claims verified → **21 confirmed, 4 killed** (`BuildRigFromAttachments` 1-2;
"CreateAssetAsync only 4 types" 0-3; "IKControl programmatically usable" 1-2; "IKControl needs Humanoid/
AnimationController parent" 1-2). Full claim/vote detail in run `wf_66374fd5-8ba`.

---

## 12. Next step

Turn §8 into a plan (writing-plans skill) — but **run LIVE-TEST #1 first**, since whether native spawn works
in edit changes whether slice D builds on a true native rig or the placeholder. Slices B–E stay deferred until
this is planned. (Per the handoff: research first, then plan from facts — done; planning is the next session.)
