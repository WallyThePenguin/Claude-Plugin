# SP2 Plan B — Oracle Factory Coupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Couple the live Roblox Oracle (SP2a) into the factory/forever loops: oracle-first playbooks whose evidence quotes magnitudes, verification-tiered RETRO lessons, a 1-in-5 stochastic capture audit that files suite-vs-capture disagreements as oracle bugs, plus the two Luau nits (suite clip default, spawn_rig MIXED-rig triage).

**Architecture:** All Python changes live in `sidecar/factory.py` + `sidecar/forever.py` (the orchestrators — modifiable per spec §3; `agent_loop.py`/`sdk_loop.py` stay untouched). Luau changes are one commit: `src/Tools/Oracle.luau` (clip default + animation suite), `src/Tools/OracleChecks.luau` (rig_channel_check default/message), `src/NativeRig.luau` (strip AnimationConstraints → uniform classic rig), `src/Config.luau` (0.25s bridge poll). Tests are dependency-free script style matching `test_factory.py`/`test_forever.py`.

**Tech Stack:** Python 3 stdlib only (sidecar rule), Luau (selene-linted, `~/.rokit/bin/selene`), dev bridge via `scripts/studio-agent.ps1`.

**Working directory:** `C:\Users\manso\Desktop\Claude-Plugin` (master — this repo commits directly to master). **NEVER `git add -A`** (deliberate dirty files); add explicit paths only.

**Spec:** `docs/superpowers/specs/2026-07-10-sp2-roblox-oracle-design.md` §3 (factory coupling), §6 (testing), §7 (acceptance).

---

## Current-state facts (verified 2026-07-10, do not re-derive)

- `sidecar/factory.py` (853 lines): `_learned_block` :52-76 (renders `entries[-count:]` `.text` only), `RESERVED_PREFIX`/`DENYLIST` :79-80, `FactoryRunner.__init__` :147 `(loop_runner, bridge, curriculum_path, store_writer, sleep=time.sleep)`, `start` :168 (has `staging_id=None` kwarg), `_run_inner` :248 (BUILD :260 → GATE :287 → VERIFY :301 calls `_verify_prompt(rung, build, playbook)` at :312 → STAGE :349, staging `entry` dict :364-379), `PLAYBOOKS` :605-768 (`melee-weapon` :606, `animation` :674; `_WEAPON_VERIFY` :506 shared by melee+ranged), `_build_prompt` :784-822 (vision/learned insertion :809-811), `_verify_prompt` :825-853 (JSON template line ends `'"reasons":["..."]}'`).
- `sidecar/forever.py`: `RETRO_JSON_RE` :29, `MAX_TOOLING_ISSUES = 40` :35, ctor :105 (has `learnings_path`/`tooling_path` kwargs), `run_token` :219 (`startedAt % 1000000`), `staging_id = f"{rung['id']}-auto-{run_token}-{done+1}"` :246, `factory.start(rung["id"], variant_hint=hint, staging_id=staging_id)` :251, `_run_retro` :388-411 (lessons filtered `isinstance(l, str)` :394-396; narrate :405-406), `_retro_prompt` :413-440 (schema line :437-439), `_append_method_lessons` :442-473 (entry dict :460-466), `_append_tooling_issues` :475-503 (schema: `title/symptom/suspectFiles/repro/seenCount/lastSeenAt`, dedupe by title, cap `MAX_TOOLING_ISSUES`, `json.dump(data, fh, indent=1)`).
- `sidecar/server.py` :60: `FACTORY = factory_mod.FactoryRunner(LOOP, _BRIDGE, _CURRICULUM, filestore.write_item)` — new ctor kwargs must default sensibly.
- `src/Tools/Oracle.luau`: `SUITES` :28-50 (only `melee-weapon`), `runSuite(family, target, rig, clip)` :52, oracle_suite descriptor :194-213 (`"Families: melee-weapon."` :197, clip described "default SwordSwing" :204).
- `src/Tools/OracleChecks.luau`: `rig_channel_check` :363 defaults clip to **"AgentClip"** (`tostring(args.clip or "AgentClip")` :369) and its UNKNOWN message prints the RAW arg (`.. tostring(args.clip)` :371 → the live-observed "AnimSaves: nil"); `clip_arc_of` :476 and `clip_self_intersect` :530 default **"SwordSwing"**. `joint_census` :338 FAILs "MIXED rig: N Motor6D + M AnimationConstraint" :355.
- `src/NativeRig.luau`: `finish()` :114-124 runs `buildJoints` (adds 15 Motor6Ds) but NEVER strips the AnimationConstraints that `CreateHumanoidModelFromDescriptionAsync` now ships (Avatar Joint Upgrade) → the live MIXED-rig catch. `src/PlayBridge.luau` `convertToMotor6D` :305-333 is the proven strip pattern (`AnimationConstraint` + `BallSocketConstraint` → Destroy).
- `src/Config.luau` :61: `devBridgePollInterval = 1.5`.
- `factory/tooling-issues.json` exists: `{"issues":[{title,symptom,suspectFiles,repro,seenCount,lastSeenAt}]}`.
- Test harness style: `test_factory.py` FakeLoop/FakeBridge/`_check`/`main()` prints PASS/FAIL rows, exits nonzero on fails; `test_forever.py` FakeFactory/FakeLoop/`retro_result(lessons, issues)` helper (bare-string lessons today).
- Existing prompt-string assertions that MUST stay true after the playbook rewrite (test_factory.py :136-143): build contains `make_tool`, `bind_hitbox`, `bind_animation`, `TWO angles`; verify contains `SKEPTIC`, `TrainingDummy`, `NEVER destroy`, `capture_angles`, `grip_tool`, `capture_animation`, `TWICE`, `angle front`, `DAMAGE ONLY`, `playtest_stop IMMEDIATELY`.

Run tests: `cd C:\Users\manso\Desktop\Claude-Plugin\sidecar; python test_factory.py; python test_forever.py` (each prints rows, exit code = fail count semantics — nonzero on failure).

---

### Task 1: RETRO verification tiers (forever.py) + tier-rendering learned block (factory.py)

**Files:**
- Modify: `sidecar/forever.py` (:388-473 region)
- Modify: `sidecar/factory.py` (:52-76 `_learned_block`)
- Test: `sidecar/test_forever.py`, `sidecar/test_factory.py`

- [ ] **Step 1: Write the failing tests**

In `sidecar/test_forever.py`, update the `retro_result` helper to pass lessons through verbatim (it already `json.dumps`s whatever it gets — no change needed), then ADD to `main()` right after the existing retro tests (search for `"retro lesson"` or the last use of `retro_result`; append this block before the mechanic tests):

```python
    # --- RETRO verification tiers (SP2b): dict lessons carry tier; legacy strings default ---
    fac = FakeFactory("PASSED")
    loop = FakeLoop([
        retro_result(lessons=[
            {"text": "measure grip via oracle_suite before any capture", "tier": "capture-confirmed"},
            "legacy bare-string lesson",
            {"text": "bogus tier is coerced", "tier": "gospel"},
            {"text": "   ", "tier": "playtest-confirmed"},  # blank text dropped
        ]),
        proposals_result([]),
    ])
    r, _ = _runner(fac, loop)
    r.start(cycles=1)
    _wait(r)
    data = json.load(open(r._learnings_path))
    entries = data.get("entries", [])
    by_text = {e["text"]: e for e in entries}
    fails += _check("tiered lesson stored with tier",
                    by_text.get("measure grip via oracle_suite before any capture", {}).get("tier") == "capture-confirmed")
    fails += _check("legacy bare string defaults symbolic-only",
                    by_text.get("legacy bare-string lesson", {}).get("tier") == "symbolic-only")
    fails += _check("invalid tier coerced symbolic-only",
                    by_text.get("bogus tier is coerced", {}).get("tier") == "symbolic-only")
    fails += _check("blank tiered lesson dropped", len(entries) == 3)
    fails += _check("retro prompt asks for tier objects",
                    any('"tier":"symbolic-only|capture-confirmed|playtest-confirmed"' in p for p in loop.prompts))
```

In `sidecar/test_factory.py`, add to `main()` (near the end, before the summary):

```python
    # --- _learned_block renders [tier] prefixes + the symbolic-only prompt rule (SP2b) ---
    d = tempfile.mkdtemp()
    old_dir = factory.LEARNINGS_DIR
    factory.LEARNINGS_DIR = d
    try:
        with open(os.path.join(d, "factory-methods.json"), "w", encoding="utf-8") as fh:
            json.dump({"category": "factory-methods", "seq": 2, "entries": [
                {"id": 1, "text": "untagged legacy lesson", "localId": 1},
                {"id": 2, "text": "suite before capture", "tier": "capture-confirmed", "localId": 2},
            ]}, fh)
        block = factory._learned_block("melee-weapon")
        fails += _check("learned block renders tier prefix", "- [capture-confirmed] suite before capture" in block)
        fails += _check("legacy lesson renders untagged", "- untagged legacy lesson" in block)
        fails += _check("learned block states the symbolic-only rule",
                        "symbolic-only" in block and "NEVER cite" in block)
    finally:
        factory.LEARNINGS_DIR = old_dir
```

- [ ] **Step 2: Run both test files, verify the new checks FAIL**

Run: `cd C:\Users\manso\Desktop\Claude-Plugin\sidecar; python test_forever.py; python test_factory.py`
Expected: the new rows print `FAIL` (tier is missing / prompt lacks the tier schema / block lacks prefixes); all pre-existing rows still `PASS`.

- [ ] **Step 3: Implement in forever.py**

Add near the top of `forever.py` (after `_ID_RE` :50):

```python
LESSON_TIERS = ("symbolic-only", "capture-confirmed", "playtest-confirmed")


def _normalize_lessons(raw):
    """RETRO methodLessons -> [{'text','tier'}]. Accepts {text,tier} objects AND legacy bare
    strings; an unlabeled or unknown tier is coerced to symbolic-only (an unlabeled lesson is
    never settled method)."""
    out = []
    for lesson in raw or []:
        if isinstance(lesson, str):
            text, tier = lesson, "symbolic-only"
        elif isinstance(lesson, dict):
            text = str(lesson.get("text") or "")
            tier = lesson.get("tier") if lesson.get("tier") in LESSON_TIERS else "symbolic-only"
        else:
            continue
        text = text.strip()
        if text:
            out.append({"text": text, "tier": tier})
    return out
```

In `_run_retro` (:394-396) replace the lessons extraction:

```python
            lessons = _normalize_lessons(retro.get("methodLessons"))
```

In `_run_retro` narrate (:405-406) replace:

```python
            for lesson in lessons[:2]:
                self._narrate(f"retro lesson [{lesson['tier']}]: {lesson['text']}")
```

In `_append_method_lessons` (:442-473): change the docstring's first line to mention tiers, and the loop body — lessons are now dicts:

```python
        for lesson in lessons:
            t = str(lesson.get("text") or "").strip()[:400]
            if not t or t in known:
                continue
            data["seq"] = int(data.get("seq") or 0) + 1
            entries.append({
                "bucket": "factory-methods",
                "id": data["seq"],
                "text": t,
                "tier": lesson.get("tier") or "symbolic-only",
                "localId": data["seq"],
                "createdAt": int(time.time()),
            })
            known.add(t)
            added += 1
```

In `_retro_prompt` (:429-439) replace item 1's text and the schema line:

```python
            "From the record ALONE (no tools - answer in ONE message), report:\n"
            "1. METHOD LESSONS: 0-2 durable one-sentence rules that would make FUTURE cycles work "
            "better (procedure/technique: 'measure X in edit before Y', 'verify Z without a "
            "playtest by ...'). NOT brief restatements, NOT one-off facts. Each lesson is an "
            "OBJECT with a VERIFICATION TIER naming the strongest evidence in THIS record backing "
            "it: 'playtest-confirmed' (observed live in a playtest), 'capture-confirmed' (seen in "
            "captures/filmstrips), 'symbolic-only' (oracle magnitudes or reasoning alone - an "
            "unproven hypothesis). When unsure, use symbolic-only.\n"
            "2. TOOLING ISSUES: defects in the FACTORY'S OWN MACHINERY that the record shows (a "
            "tool erroring, a wedge, evidence impossible to gather) - NOT content-quality "
            "problems. Empty lists are fine - do not invent.\n\n"
            "Your message must be ONLY this line:\n"
            'FACTORY_RETRO_JSON: {"methodLessons":[{"text":"...",'
            '"tier":"symbolic-only|capture-confirmed|playtest-confirmed"}],'
            '"toolingIssues":[{"title":"...",'
            '"symptom":"<verbatim error/behaviour>","suspectFiles":["src/..."],'
            '"repro":"<how to reproduce in EDIT mode>"}]}'
```

- [ ] **Step 4: Implement `_learned_block` tier rendering in factory.py**

Replace the pick loop and return (:66-76):

```python
        for e in entries[-count:]:
            e = e if isinstance(e, dict) else {}
            t = str(e.get("text") or "").strip()
            if not t:
                continue
            tier = e.get("tier")
            picks.append((f"[{tier}] " if tier else "") + t)
    if not picks:
        return ""
    return (
        "LEARNED METHODS (banked from past cycles - apply these FIRST):\n"
        + "\n".join("- " + t for t in picks)
        + "\nTier rule: a [symbolic-only] lesson is an unconfirmed hypothesis from oracle "
        "numbers alone - try it, but NEVER cite it as settled method; [capture-confirmed] and "
        "then [playtest-confirmed] carry increasing weight. Untagged lessons predate tiers.\n\n"
    )
```

- [ ] **Step 5: Run both test files, verify ALL rows pass**

Run: `python test_forever.py; python test_factory.py`
Expected: every row `PASS` (legacy retro tests keep passing — bare strings normalize).

- [ ] **Step 6: Commit**

```powershell
git add sidecar/forever.py sidecar/factory.py sidecar/test_forever.py sidecar/test_factory.py
git commit -m "feat(sidecar): RETRO lessons carry verification tiers; learned block renders + gates them (SP2b T1)"
```

---

### Task 2: Shared tooling-issues appender (DRY move to factory.py)

**Files:**
- Modify: `sidecar/factory.py` (new module function + constant)
- Modify: `sidecar/forever.py` (:35, :475-503 delegate)
- Test: existing suites only (pure refactor — behavior identical)

- [ ] **Step 1: Add to factory.py** (below `_learned_block`, above `RESERVED_PREFIX`):

```python
MAX_TOOLING_ISSUES = 40
TOOLING_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "factory", "tooling-issues.json"
)


def append_tooling_issues(issues, path):
    """Append tooling defects to the mechanic's backlog file, deduped by title (shared by
    forever's RETRO stage and the factory's capture-audit oracle-bug filing)."""
    if not issues:
        return
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {"issues": []}
    bucket = data.setdefault("issues", [])
    by_title = {i.get("title"): i for i in bucket if isinstance(i, dict)}
    for issue in issues:
        title = str(issue.get("title"))[:200]
        if title in by_title:
            by_title[title]["seenCount"] = int(by_title[title].get("seenCount") or 1) + 1
            by_title[title]["lastSeenAt"] = int(time.time())
            continue
        bucket.append({
            "title": title,
            "symptom": str(issue.get("symptom") or "")[:600],
            "suspectFiles": issue.get("suspectFiles") or [],
            "repro": str(issue.get("repro") or "")[:600],
            "seenCount": 1,
            "lastSeenAt": int(time.time()),
        })
    del bucket[:-MAX_TOOLING_ISSUES]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1)
```

- [ ] **Step 2: Delegate in forever.py**

Replace `MAX_TOOLING_ISSUES = 40` (:35) with `MAX_TOOLING_ISSUES = factory_mod.MAX_TOOLING_ISSUES` — CAREFUL: :35 sits above the imports? No — imports are :25-26, so this works. Replace the whole `_append_tooling_issues` body (:475-503) with:

```python
    def _append_tooling_issues(self, issues):
        """Append tooling defects to the mechanic's backlog file (shared impl in factory.py)."""
        factory_mod.append_tooling_issues(issues, self._tooling_path)
```

- [ ] **Step 3: Run all four sidecar suites**

Run: `python test_factory.py; python test_forever.py; python test_agent_loop.py; python test_sdk_loop.py`
Expected: all rows PASS (test_forever :307 reads the same file shape).

- [ ] **Step 4: Commit**

```powershell
git add sidecar/factory.py sidecar/forever.py
git commit -m "feat(sidecar): shared tooling-issues appender in factory.py (SP2b T2)"
```

---

### Task 3: Stochastic 1-in-5 capture audit (factory.py)

**Files:**
- Modify: `sidecar/factory.py` (`import zlib`; `_audit_pick`; ctor `tooling_path` kwarg; `_run_inner` audit wiring; `_verify_prompt` audit blocks; staging entry + status `audit` flag)
- Test: `sidecar/test_factory.py`

- [ ] **Step 1: Write the failing tests** (append to `main()`):

```python
    # --- stochastic capture audit (SP2b): deterministic 1-in-5, keyed on the run token ---
    picks = [factory._audit_pick(f"tok-{i}") for i in range(200)]
    fails += _check("audit pick deterministic", picks == [factory._audit_pick(f"tok-{i}") for i in range(200)])
    rate = sum(picks)
    fails += _check("audit pick ~1-in-5", 20 <= rate <= 60)
    audit_tok = next(f"aud-{i}" for i in range(100) if factory._audit_pick(f"aud-{i}"))
    plain_tok = next(f"aud-{i}" for i in range(100) if not factory._audit_pick(f"aud-{i}"))

    # audit run: verify prompt gains AUDIT MODE + oracleAudit schema; disagreements are filed
    d = tempfile.mkdtemp()
    tooling = os.path.join(d, "tooling-issues.json")
    audit_verdict = {
        "status": "PASSED",
        "evidence": {"summary": "grip 0.0 studs / 0.3 deg; sweep 96.8 deg; damage 20 exact"},
        "reasons": [],
        "oracleAudit": {"disagreements": [
            {"check": "grip_sane", "suiteSaid": "PASS 0.3 deg", "captureShowed": "blade points into forearm"},
        ]},
    }
    loop = FakeLoop([
        {"state": "done", "result": build_line()},
        {"state": "done", "result": "FACTORY_VERIFY_JSON: " + json.dumps(audit_verdict)},
    ])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    store = {}
    r = _runner(loop, bridge, store, tooling_path=tooling)
    r.start("weapon-spear", staging_id=audit_tok)
    st = _wait(r)
    fails += _check("audit run flagged in status", st.get("audit") is True)
    fails += _check("audit prompt has AUDIT MODE", "AUDIT MODE" in loop.prompts[1])
    fails += _check("audit prompt extends the JSON schema", "oracleAudit" in loop.prompts[1])
    fails += _check("audit flag rides the staging entry", store[("staging", audit_tok)].get("audit") is True)
    filed = json.load(open(tooling))
    titles = [i.get("title", "") for i in filed.get("issues", [])]
    fails += _check("disagreement filed as ORACLE BUG", any(t.startswith("ORACLE BUG:") and "grip_sane" in t for t in titles))

    # non-audit run: no AUDIT MODE, nothing filed
    loop = FakeLoop([
        {"state": "done", "result": build_line()},
        {"state": "done", "result": verify_line("PASSED")},
    ])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    store = {}
    tooling2 = os.path.join(tempfile.mkdtemp(), "tooling-issues.json")
    r = _runner(loop, bridge, store, tooling_path=tooling2)
    r.start("weapon-spear", staging_id=plain_tok)
    st = _wait(r)
    fails += _check("plain run not audited", st.get("audit") is not True and "AUDIT MODE" not in loop.prompts[1])
    fails += _check("plain run files nothing", not os.path.exists(tooling2))
```

And update the `_runner` helper (:94-99) to accept/forward the kwarg:

```python
def _runner(loop, bridge, store, curriculum=CURRICULUM, tooling_path=None):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "curriculum.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(curriculum, fh)
    return factory.FactoryRunner(loop, bridge, path, _writer(store), sleep=lambda s: None,
                                 tooling_path=tooling_path)
```

- [ ] **Step 2: Run, verify new rows FAIL** (`python test_factory.py`)

- [ ] **Step 3: Implement in factory.py**

Add `import zlib` to the imports (:22-26, alphabetical: after `time`). Add below `append_tooling_issues`:

```python
AUDIT_EVERY = 5


def _audit_pick(token) -> bool:
    """Deterministic 1-in-AUDIT_EVERY selection keyed on the run token (spec §3: the stochastic
    capture audit must be reproducible, not random)."""
    return zlib.crc32(str(token).encode("utf-8")) % AUDIT_EVERY == 0
```

Ctor (:147): add `tooling_path=None` kwarg; in the body: `self._tooling_path = tooling_path or TOOLING_PATH`.

`_run_inner` VERIFY section (:301-312): compute + surface the flag, pass it to the prompt:

```python
        # ---- VERIFY ----
        audit = _audit_pick(staging_id or f"{rung_id}#{run_id}")
        self._set(stage="verify", audit=audit)
        self._narrate(
            f"VERIFY {rung_id}{' [AUDIT MODE: full capture cross-check]' if audit else ''}: "
            "gathering edit-first evidence, then the verdict"
        )
```

and the loop call becomes `_verify_prompt(rung, build, playbook, audit)`.

After `result["verify"] = verify` (:340), file disagreements:

```python
        if audit:
            result["audit"] = True
            oa = verify.get("oracleAudit")
            dis = (oa.get("disagreements") if isinstance(oa, dict) else None) or []
            bugs = []
            for item in dis[:8]:
                if not isinstance(item, dict) or not item.get("check"):
                    continue
                bugs.append({
                    "title": f"ORACLE BUG: {str(item.get('check'))[:60]} - suite vs capture disagree ({rung_id})",
                    "symptom": f"suite said: {str(item.get('suiteSaid') or '?')[:200]} | capture showed: "
                               f"{str(item.get('captureShowed') or '?')[:200]}",
                    "suspectFiles": ["src/Tools/OracleChecks.luau", "src/Tools/Oracle.luau"],
                    "repro": f"oracle_suite on {build.get('artifactPath')} vs a full capture review "
                             f"(audit run, rung {rung_id})",
                })
            if bugs:
                try:
                    append_tooling_issues(bugs, self._tooling_path)
                    self._narrate(f"AUDIT: {len(bugs)} suite-vs-capture disagreement(s) filed as ORACLE BUGs", warn=True)
                except OSError:
                    pass  # filing is best-effort; never fails the run
```

Staging entry (:364-379) gains `"audit": audit,` after `"headless": True,`.

`_verify_prompt` (:825): new signature `def _verify_prompt(rung, build, playbook: dict, audit: bool = False) -> str:`. Before the `return`, build the audit pieces:

```python
    audit_block = (
        "AUDIT MODE (this run was deterministically selected, 1-in-5): even if the oracle suite "
        "is fully GREEN, ALSO run the FULL capture review (every angle/filmstrip the procedure "
        "names) and CROSS-CHECK each suite verdict against what the captures show. Report any "
        "disagreement in the verdict JSON's \"oracleAudit\" field (empty disagreements list when "
        "they agree). A disagreement does NOT change your verdict rules - it files an oracle bug "
        "for the mechanic (gap-mining).\n\n"
        if audit
        else ""
    )
```

insert `+ audit_block` right after `+ _learned_block(rung.get("family"))`, and change the JSON template tail: replace the final `'"...","reasons":["..."]}'` fragment with

```python
        'FACTORY_VERIFY_JSON: {"status":"PASSED|FAILED|UNVERIFIED","evidence":{"summary":'
        '"<one-sentence probe output or capture-vs-reference finding>"},"reasons":["..."]'
        + (',"oracleAudit":{"disagreements":[{"check":"<name>","suiteSaid":"<verdict + magnitude>",'
           '"captureShowed":"<what the frames show>"}]}' if audit else "")
        + "}"
    )
```

- [ ] **Step 4: Run, verify ALL rows pass** (`python test_factory.py; python test_forever.py`)

- [ ] **Step 5: Commit**

```powershell
git add sidecar/factory.py sidecar/test_factory.py
git commit -m "feat(sidecar): 1-in-5 deterministic capture audit files suite-vs-capture disagreements as ORACLE BUGs (SP2b T3)"
```

---

### Task 4: Oracle-first playbooks (melee-weapon + animation) + prompt insertions

**Files:**
- Modify: `sidecar/factory.py` (PLAYBOOKS melee-weapon/animation; new `_MELEE_ORACLE_VERIFY`; `oracleFamily` flag; `_ORACLE_BUILD`; `_build_prompt`/`_verify_prompt` insertions)
- Test: `sidecar/test_factory.py`

- [ ] **Step 1: Write the failing tests** (append to `main()`):

```python
    # --- oracle-first playbooks (SP2b): stamp_frame in build, oracle_suite-first verify ---
    loop = FakeLoop([{"state": "done", "result": build_line()}, {"state": "done", "result": verify_line("PASSED")}])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    store = {}
    r = _runner(loop, bridge, store)
    r.start("weapon-spear")
    _wait(r)
    bp, vp = loop.prompts[0], loop.prompts[1]
    fails += _check("melee build stamps the frame before make_tool", "stamp_frame" in bp and bp.index("stamp_frame") < bp.index("make_tool"))
    fails += _check("melee build grips via frame alignment", "NO offset/rot" in bp)
    fails += _check("melee build self-checks with the suite", "oracle_suite" in bp)
    fails += _check("melee build names the clip SwordSwing", "SwordSwing" in bp)
    fails += _check("melee verify is oracle-first", "ORACLE-FIRST" in vp and vp.index("oracle_suite") < vp.index("capture_angles"))
    fails += _check("melee verify demands magnitude quotes", "MUST QUOTE" in vp and "adjectives" in vp)
    fails += _check("melee verify scopes captures to flagged + sign-off", "FLAGGED" in vp and "sign-off" in vp)
    fails += _check("melee verify keeps the damage twin", "TrainingDummy" in vp and "DAMAGE ONLY" in vp)
    # legacy visual family untouched by the oracle blocks
    loop = FakeLoop([{"state": "done", "result": build_line(artifactPath="game.Workspace.Cottage", artifactKind="Model")},
                     {"state": "done", "result": verify_line("PASSED")}])
    bridge = FakeBridge({"GetAttributes": GATE_CLEAN, "FactoryStaging": STAGE_OK})
    r = _runner(loop, bridge, {})
    r.start("house-cottage")
    _wait(r)
    fails += _check("non-oracle family build has no frame block", "stamp_frame" not in loop.prompts[0])
    fails += _check("non-oracle family verify has no oracle block", "ORACLE-FIRST" not in loop.prompts[1])
    # animation family is oracle-first too
    fails += _check("animation playbook flags its suite family",
                    factory.PLAYBOOKS["animation"].get("oracleFamily") == "animation")
    fails += _check("animation verify is oracle-first", "oracle_suite" in factory.PLAYBOOKS["animation"]["verify"])
    fails += _check("animation build census-checks the rig", "joint_census" in factory.PLAYBOOKS["animation"]["build"])
```

- [ ] **Step 2: Run, verify new rows FAIL; existing playbook rows still PASS**

- [ ] **Step 3: Implement in factory.py**

(a) Below `_VISION_BUILD`, add:

```python
_ORACLE_BUILD = (
    "SEMANTIC FRAME DISCIPLINE (oracle-first): declare semantics at BUILD time, never leave them "
    "to be inferred at verify time - stamp_frame the family schema BEFORE make_tool (read_frame "
    "shows what is still missing), grip via FRAME ALIGNMENT (grip_tool with NO offset/rot args - "
    "it aligns Semantic_Grip to the hand and stamps the resulting grip back), and BEFORE emitting "
    "FACTORY_BUILD_JSON run oracle_suite {family:'%s', target:<artifact>} as a self-check: fix "
    "every FAIL row and quote at least one magnitude as a NUMBER in notes (e.g. grip 0.0 studs / "
    "0.3 deg)."
)
```

(b) New melee verify text — replace `"verify": _WEAPON_VERIFY` in the **melee-weapon** playbook ONLY (ranged-weapon keeps `_WEAPON_VERIFY` unchanged) with `"verify": _MELEE_ORACLE_VERIFY`, defined next to `_WEAPON_VERIFY`:

```python
_MELEE_ORACLE_VERIFY = (
    "The game's round/wave/spawner scripts are auto-disabled and stray mobs cleared for this "
    "verify (a CALM sandbox). This verify is ORACLE-FIRST - measure with the suite, look only "
    "where it points, then sign off aesthetics:\n"
    "(1) ORACLE SUITE BEFORE ANY CAPTURE: record Tool.Grip and Tool.Parent via run_luau, "
    "grip_tool the weapon onto workspace.AgentRig (spawn_rig if missing) with NO offset/rot args "
    "(frame alignment), then run oracle_suite {family:'melee-weapon', target:<the Tool's path "
    "UNDER the rig>, rig:'game.Workspace.AgentRig', clip:'SwordSwing'}. Read EVERY row. Your "
    "evidence MUST QUOTE the magnitudes as NUMBERS with units - grip_offset_studs, "
    "blade_up_angle_deg, sweep_deg, max_reach_studs, penetration depths - adjectives ('aligned', "
    "'smooth', 'looks right') are NOT evidence. UNKNOWN rows never count as pass; say why each "
    "UNKNOWN is unknown.\n"
    "(2) CAPTURES ONLY WHERE THE SUITE POINTS + ONE SIGN-OFF: (a) for each FAILED or UNKNOWN row, "
    "capture exactly what is needed to diagnose it (a flagged grip -> capture the held pose; a "
    "flagged clip -> capture_animation that clip); (b) then ONE final aesthetic sign-off - "
    "capture_angles the Tool (count 3-4, neutralLight=true) and capture_animation the swing at "
    "least TWICE, once with angle front, once with angle right or iso (frames 5-6 each) - the "
    "suite's blindspot manifest lists exactly what was NOT asserted (silhouette, materials, swing "
    "FEEL) and that is what your eyes are for. If a strip is UNREADABLE (silhouette/occlusion), "
    "re-shoot before judging. FAIL if any suite FAIL row stands unexplained, or the sign-off "
    "shows the weapon not READING as the brief's weapon. Afterward RESTORE via run_luau: destroy "
    "the 'AgentEditGrip' weld under the rig's RightHand, set Grip back, and reparent the Tool to "
    "its recorded parent.\n"
    "(3) EDIT - THE DUMMY: locate workspace.TrainingDummy with run_luau and print BOTH its "
    "Position AND the SpawnLocation's Position (it may be BESIDE spawn - compute the offset so you "
    "know exactly which way and how far to walk; do NOT assume 'straight ahead'). If MISSING, "
    "create it: clone ServerStorage.VerifyDummy (or EnemyTemplate, deleting its scripts), name it "
    "'TrainingDummy', SetAttribute('StudioAgentGenerated', nil), add a Script that on "
    "Humanoid.HealthChanged prints '[TrainingDummy] HIT damage=<n> hitcount=<n>' then resets "
    "Health=MaxHealth, MaxHealth=10000, anchor every BasePart, PivotTo ~5 studs from the "
    "SpawnLocation on OPEN floor. PERMANENT fixture: NEVER destroy or move it.\n"
    "(4) PLAYTEST - DAMAGE ONLY, IN AND OUT: playtest_start; playtest_act record (the echo ends "
    "[tool=<name> w=<x> a=<y> c=<z>] - FAIL if the tool name or echoed config does not match the "
    "build's config); walk to the dummy along the measured offset, face it, swing 2-3 times; "
    "playtest_logs and read the '[TrainingDummy] HIT damage=' lines - FAIL unless a hit's damage "
    "EXACTLY equals the configured damage (a broken or sabotaged weapon prints NO hit line), and "
    "FAIL on any error mentioning the artifact. The MOMENT the damage lines are read - or after "
    "~3 failed approach attempts (note the mobility trouble, judge on the evidence you have) - "
    "playtest_stop IMMEDIATELY. Never linger in play mode; the measured evidence is already "
    "banked from EDIT."
)
```

(steps 3-4 are verbatim from `_WEAPON_VERIFY` — the damage twin and dummy discipline are unchanged.)

(c) melee-weapon playbook: add `"oracleFamily": "melee-weapon",` and rewrite `build` steps 3-5 (keep 1, 2, 6, 7, 8 verbatim):

```python
            "(3) stamp_frame the melee-weapon frame on the assembled model BEFORE make_tool: "
            "points Grip + BladeTip, dirs blade_dir + edge_dir, roles hilt + blade (Handle-local "
            "coords - the stamp_frame description documents the schema); then make_tool with the "
            "grip part as Handle; "
            "(4) ANIMATE THE SWING in EDIT (no playtest): on workspace.AgentRig (spawn_rig if "
            "missing) author a 3-keypose right-arm swing clip NAMED 'SwordSwing' (the oracle "
            "suite's default clip name) - add_keyframe scope rightArm: windup back, strike "
            "through, recover; total ~0.6-0.9s per the brief's speed - then bind_animation "
            "{tool, event='use', clip} so the weapon ACTUALLY ANIMATES when used; "
            "(5) MEASURE, THEN PREVIEW: record Tool.Grip and Tool.Parent via run_luau, grip_tool "
            "the weapon onto the rig with NO offset/rot args (frame alignment - a stamped frame "
            "makes mis-grips impossible), run oracle_suite {family:'melee-weapon', target:<the "
            "Tool under the rig>, rig:'game.Workspace.AgentRig', clip:'SwordSwing'} and FIX every "
            "FAIL row (grip_sane's blade_up_angle_deg and clip_arc_of's sweep_deg are your "
            "numbers - quote one in notes); then ONE aesthetic capture_animation pass from TWO "
            "angles (front, then right or iso, frames 5-6 each) for what numbers cannot see - "
            "readability, silhouette, the blade visibly out of the fist; if the strip is "
            "unreadable re-shoot once; then RESTORE via run_luau: destroy the 'AgentEditGrip' "
            "weld under the rig's RightHand, set Grip back, and reparent the Tool out of the "
            "rig; "
```

(d) animation playbook: add `"oracleFamily": "animation",` and update:

```python
        "build": (
            "(1) use an existing rig or spawn_rig; FIRST run oracle_check {check:'joint_census', "
            "args:{rig:<rig>}} - a MIXED Motor6D/AnimationConstraint rig will silently T-pose "
            "your clip; fix the rig before authoring; (2) author the clip as KEYPOSES: pose_joint "
            "/ ik_reach into each keypose then add_keyframe to snapshot it, repeated per pose, "
            "with KeyframeMarkers if the brief needs contact/cancel points; (3) after authoring, "
            "oracle_check {check:'rig_channel_check', args:{rig:<rig>, clip:<clipName>}} - "
            "unmapped pose names are silently-dead channels; fix them before filming; (4) the "
            "artifact is the clip/KeyframeSequence. Author with NO preview running; review with "
            "capture_animation from at least TWO angles (front, then right or iso) - "
            "imperfections hide from one angle."
        ),
        "verify": (
            "ORACLE-FIRST: (1) run oracle_suite {family:'animation', target:<the rig>, rig:<the "
            "rig>, clip:<the config's clipName>} BEFORE any filmstrip - quote its magnitudes as "
            "NUMBERS (motor6d/constraint counts, unmapped channel names) in your evidence; a "
            "MIXED rig or dead channel FAILs regardless of how the filmstrip looks. (2) "
            "capture_animation filmstrips from at least TWO angles - one call with angle front, "
            "another with angle right or iso (frames 5-6 each), judging each as it arrives "
            "(foot-slide, clipping, and broken arcs are suite BLINDSPOTS - the manifest says so; "
            "they are exactly what the filmstrips are for); (3) get_references for the motion and "
            "check the arc/timing/weight; (4) grade against the animation rubric - the motion "
            "must READ as the intended action from EVERY angle (correct arc, torso lead, no "
            "foot-slide, no limb clipping, clean start/end); PASS only if it clearly reads right; "
            "FAILED with what's off; UNVERIFIED if you cannot render the filmstrip."
        ),
```

(e) `_build_prompt` insertion (after the `_VISION_BUILD` line :810):

```python
        + (_ORACLE_BUILD % playbook["oracleFamily"] + "\n\n" if playbook.get("oracleFamily") else "")
```

(f) `_verify_prompt` oracle block — add before the return (next to Task 3's `audit_block`):

```python
    oracle_fam = playbook.get("oracleFamily")
    oracle_block = (
        f"ORACLE-FIRST (standing rule): your FIRST evidence action is oracle_suite "
        f"{{family:'{oracle_fam}', target:'{build.get('artifactPath')}'}} with the rig/clip args "
        "the approach below names. The suite is the MEASUREMENT layer; captures are reserved for "
        "rows the suite FLAGGED plus ONE final aesthetic sign-off (its blindspot manifest lists "
        "exactly what was NOT asserted - that is what your eyes are for). Your evidence MUST "
        "QUOTE suite magnitudes as NUMBERS with units - adjectives are not evidence. A green "
        "suite alone is never 'done'.\n\n"
        if oracle_fam
        else ""
    )
```

inserted `+ oracle_block` after `+ _learned_block(rung.get("family"))` (before `audit_block`).

- [ ] **Step 4: Run, verify ALL rows pass** — including the pre-existing :136-143 string assertions (`make_tool`, `bind_animation`, `bind_hitbox`, `TWO angles`, `TrainingDummy`, `NEVER destroy`, `capture_angles`, `grip_tool`, `capture_animation`, `TWICE`, `angle front`, `DAMAGE ONLY`, `playtest_stop IMMEDIATELY` all survive in the new texts).

Run: `python test_factory.py; python test_forever.py`

- [ ] **Step 5: Commit**

```powershell
git add sidecar/factory.py sidecar/test_factory.py
git commit -m "feat(sidecar): oracle-first melee/animation playbooks - frame-stamped builds, magnitude-quoting verify (SP2b T4)"
```

---

### Task 5: Luau nits — suite clip default, animation suite, spawn_rig classic-rig strip, 0.25s poll (one commit)

**Files:**
- Modify: `src/Tools/OracleChecks.luau` (:363-372)
- Modify: `src/Tools/Oracle.luau` (:28-50 SUITES, :52 runSuite, :197 + :204 descriptor text)
- Modify: `src/NativeRig.luau` (:1-6 header, :114-124 `finish`)
- Modify: `src/Config.luau` (:61)
- Modify: `factory/tooling-issues.json` (file the triage decision — oracle catch #1)

- [ ] **Step 1: OracleChecks.rig_channel_check — unify the default + honest message**

Replace :368-372:

```lua
	local clipName = tostring(args.clip or "SwordSwing")
	local saves = rig:FindFirstChild("AnimSaves")
	local ks = if saves ~= nil then saves:FindFirstChild(clipName) else nil
	if ks == nil or not ks:IsA("KeyframeSequence") then
		return unknown("clip not found under rig/AnimSaves: " .. clipName)
	end
```

(kills the live-observed `AnimSaves: nil`; the searched name and the reported name can no longer diverge, and the default now matches clip_arc_of/clip_self_intersect and the tool schema's documented "SwordSwing".)

- [ ] **Step 2: Oracle.luau — suite-level clip default + animation suite**

In `runSuite` (:52), default the clip ONCE before templating, so no check ever sees a nil threaded past its own default:

```lua
local function runSuite(family: string, target: string, rig: string?, clip: string?): any
	local clipName = clip or "SwordSwing"
```

and change the melee suite's `checks` calls to use it (the function already receives it as the third arg — pass `clipName` at the call site :64: `suite.checks(target, rig, clipName)`).

Add the animation suite to `SUITES` after the melee entry (data-only; both checks already exist):

```lua
	["animation"] = {
		-- target doubles as the rig path when no separate rig is given (animation rungs ARE rigs).
		checks = function(target: string, rig: string?, clip: string?)
			local r = rig or target
			return {
				{ check = "joint_census", args = { rig = r } },
				{ check = "rig_channel_check", args = { rig = r, clip = clip } },
			}
		end,
		notAsserted = {
			"arc/timing/weight vs references (filmstrip judgment)",
			"foot-slide and limb clipping (capture-only)",
			"tip sweep / self-intersection without a gripped Tool (clip_arc_of needs Semantic_BladeTip)",
			"animation under the runtime Animator with locomotion blending (PLAY_ONLY twin)",
		},
	},
```

Update the oracle_suite descriptor (:197): `.. "asserted — those items still need captures/rubric judgment). Families: melee-weapon, animation."`

- [ ] **Step 3: NativeRig — strip the physical joints (oracle catch #1 fix)**

In `finish()` (:114-124), after `NativeRig.buildJoints(model)` add the strip (mirrors the live-proven `PlayBridge.convertToMotor6D` :325-331 — the Avatar Joint Upgrade ships AnimationConstraints that override/ignore the Motor6D animation channel):

```lua
local function finish(model: Model, colored: boolean): Model
	model.Name = "AgentRig"
	model.Parent = Workspace
	NativeRig.buildJoints(model)
	-- Avatar Joint Upgrade rigs ship AnimationConstraints (+BallSocketConstraints) that override /
	-- ignore the Motor6D animation channel — the T-pose trap joint_census caught live (oracle catch
	-- #1). Strip them so spawn_rig yields a uniform CLASSIC Motor6D rig (same conversion PlayBridge
	-- applies to play-mode characters).
	for _, d in model:GetDescendants() do
		if d:IsA("AnimationConstraint") or d:IsA("BallSocketConstraint") then
			d:Destroy()
		end
	end
	NativeRig.placeOnBaseplate(model)
	NativeRig.anchorRoot(model)
	if colored then
		NativeRig.colorParts(model)
	end
	return model
end
```

Also update the header comment (:2-6): after "we build the 15 joints from the attachment pairs", append "then strip the joint-upgrade AnimationConstraints/BallSocketConstraints (MIXED rigs half-play Motor6D clips — joint_census FAILs them)".

DECISION RECORD (goes in tooling-issues.json, step 5): we STRIP in spawn_rig rather than adding a "constraints-inert" nuance to joint_census — the check stays strict because a mixed rig is genuinely dangerous (the play-mode Animator can prefer the constraint channel and T-pose Motor6D-authored clips; this is the project's own 2026-06-26 blocker class), and the fixture becomes the thing the doctrine says it must be: a classic Motor6D rig.

- [ ] **Step 4: Config.luau :61** — `devBridgePollInterval = 0.25, -- seconds between bridge poll ticks (0.25 = snappy tool round-trips; was 1.5)`

- [ ] **Step 5: File oracle catch #1 in factory/tooling-issues.json**

Prepend this entry to the `issues` array (hand-edit; keep valid JSON, `indent=1` style):

```json
  {
   "title": "ORACLE CATCH #1: joint_census flagged spawn_rig's fixture as a MIXED rig (15 Motor6D + 15 AnimationConstraint)",
   "symptom": "oracle_check joint_census on workspace.AgentRig -> FAIL 'MIXED rig: 15 Motor6D + 15 AnimationConstraint (animations will half-play)' - the Avatar Joint Upgrade ships AnimationConstraints that NativeRig.buildJoints never stripped",
   "suspectFiles": ["src/NativeRig.luau"],
   "repro": "spawn_rig, then oracle_check {check:'joint_census', args:{rig:'game.Workspace.AgentRig'}} on a pre-fix build",
   "seenCount": 1,
   "lastSeenAt": 1783300000,
   "resolution": "FIXED in SP2b T5: NativeRig.finish strips AnimationConstraints+BallSocketConstraints after buildJoints (the PlayBridge.convertToMotor6D pattern). joint_census stays STRICT - no constraints-inert nuance; a mixed rig is the T-pose trap class and must FAIL."
  },
```

(the appender tolerates extra keys; `resolution` documents the triage per the plan scope. Set `lastSeenAt` to the current epoch at execution time.)

- [ ] **Step 6: Lint + hot-reload + live verification (requires Studio + dev bridge up)**

```powershell
& "$env:USERPROFILE\.rokit\bin\selene" src/Tools/Oracle.luau src/Tools/OracleChecks.luau src/NativeRig.luau src/Config.luau
.\scripts\studio-agent.ps1 reload
```

Expected: selene 0 errors 0 warnings; reload OK. Then over the bridge:

1. `.\scripts\studio-agent.ps1 luau 'return game.Name'` → the place name (bridge alive).
2. `oracle_check {check:"__selftest"}` → PASS, 7/7 rows (tool via `.\scripts\studio-agent.ps1 tool oracle_check '{"check":"__selftest"}'` or the equivalent bridge call).
3. Respawn the fixture: destroy `workspace.AgentRig` if present (ours, not the user's `Rig`/`UAL2_Standard`), `spawn_rig`, then `oracle_check {check:"joint_census", args:{rig:"game.Workspace.AgentRig"}}` → **PASS uniform motor6d 15** (the MIXED FAIL is gone at the source).
4. `oracle_suite {family:"animation", target:"game.Workspace.AgentRig"}` → runs; the rig_channel_check row reports `clip not found under rig/AnimSaves: SwordSwing` (named default, NOT "nil") or PASS if a clip exists.
5. `oracle_suite {family:"melee-weapon", target:...}` on any Tool → rig_channel_check row never says "AnimSaves: nil".

- [ ] **Step 7: Commit**

```powershell
git add src/Tools/Oracle.luau src/Tools/OracleChecks.luau src/NativeRig.luau src/Config.luau factory/tooling-issues.json
git commit -m "fix(tools): unify suite clip default (no more 'AnimSaves: nil'), animation suite, spawn_rig strips joint-upgrade constraints (oracle catch #1), 0.25s bridge poll (SP2b T5)"
```

---

### Task 6: Docs — HANDOFF top block + spec checkbox state

**Files:**
- Modify: `HANDOFF.md` (new START HERE block above the current top block)
- Modify: `docs/superpowers/plans/2026-07-10-sp2b-oracle-factory-coupling.md` (check off completed boxes)

- [ ] **Step 1:** Write a new top block in HANDOFF.md: SP2b factory coupling SHIPPED — oracle-first melee/animation playbooks (evidence quotes magnitudes; frame-stamped builds; SwordSwing clip convention), RETRO tier-tagged lessons ({text,tier} objects; `_learned_block` renders `[tier]` + the never-cite-symbolic-only rule; legacy strings normalize), deterministic 1-in-5 capture audit (`_audit_pick` crc32 on the run token; disagreements → ORACLE BUG entries in factory/tooling-issues.json), shared `append_tooling_issues`, Luau: suite clip default unified to SwordSwing (the "AnimSaves: nil" nit), animation suite added, spawn_rig strips joint-upgrade constraints (oracle catch #1 FIXED — decision recorded in tooling-issues.json), devBridgePollInterval 1.5→0.25. Note: SSE push-channel remains a SEPARATE follow-up (not started). State what the acceptance demo showed (fill in after the demo). Test counts: report actual.
- [ ] **Step 2:** Commit:

```powershell
git add HANDOFF.md docs/superpowers/plans/2026-07-10-sp2b-oracle-factory-coupling.md
git commit -m "docs: HANDOFF - SP2b oracle factory coupling shipped"
```

---

### Task 7: Acceptance demo (spec §7 — run by the orchestrator, NOT a subagent; ping the user to watch FIRST)

Preconditions: Studio open + dev bridge live (`.\scripts\studio-agent.ps1 luau 'return game.Name'`); sidecar running the SDK loop (`cd sidecar; python server.py` with `CLAUDE_CODE_OAUTH_TOKEN` exported from the User registry env — fresh shells won't inherit it from stale parents); factory owns the bridge during runs — never drive `/agent`/`tool` calls alongside a run.

- [ ] **(a) Mis-grip caught twice, no capture involved:** build/reuse a sword Tool via the frame flow (stamp_frame → make_tool → grip_tool no-args onto AgentRig); `oracle_check grip_sane` → PASS with magnitudes ~0 studs / ~0°. Then via `run_luau`, hand-author the mis-grip AROUND the tools: `Tool.Grip = Tool.Grip * CFrame.Angles(0, 0, math.rad(90))` (re-grip so the weld reflects it) → `grip_sane` **FAILs quoting the angle in degrees (~90)**. Then `grip_tool` with no args again → auto-realigns from the frame → `grip_sane` PASS again. Caught twice: impossible to author via the tool, and caught symbolically when authored by hand.
- [ ] **(b) One factory weapon-sword cycle** (`.\scripts\studio-agent.ps1 factory weapon-sword` or POST /factory) whose VERIFY evidence quotes oracle magnitudes (numbers in `evidence.summary`).
- [ ] **(c) Show the artifacts:** tier-tagged lessons in `sidecar/store/learnings/factory-methods.json`; the blindspot manifest in the suite output; if the 1-in-5 landed (check `status.audit`), the ORACLE BUG path in `factory/tooling-issues.json` — otherwise demonstrate the selection determinism (`_audit_pick`) and show the audit prompt block from the transcript of a forced audit staging id.
- [ ] **(d) Two forever cycles** (`.\scripts\studio-agent.ps1 forever 2`) consuming oracle results; show the cycle history + tier-tagged RETRO output.
- [ ] Update HANDOFF's demo line + memory (charter SP2a status block → SP2 COMPLETE state) after the demo.

---

## Self-review (done at authoring)

- **Spec coverage:** §3 playbooks (T4), §3 magnitudes rule (T4 f), §3 audit (T3), §3 tiers (T1), §6 Python tests (T1/T3/T4 steps), §6 Luau selftest reuse (T5 step 6), §7 demo (T7), scope item 5 nits+triage (T5), item 6 poll interval (T5) + SSE explicitly NOT started (T6 note). Non-goals respected: no agent_loop.py/sdk_loop.py changes.
- **Type consistency:** `_normalize_lessons` returns `[{'text','tier'}]` consumed by `_append_method_lessons` (T1); `append_tooling_issues(issues, path)` used by forever (T2) and the audit filer (T3); `_verify_prompt(rung, build, playbook, audit=False)` matches the T3 call site; `oracleFamily` values equal the Luau SUITES keys (`melee-weapon`, `animation` — T4 vs T5 step 2).
- **Placeholder scan:** none — all code complete.
