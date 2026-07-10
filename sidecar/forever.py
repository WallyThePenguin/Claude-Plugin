"""forever.py — the endless curriculum loop ("build anything, forever").

Cycles the PROVEN curriculum families round-robin; each cycle runs ONE headless factory iteration
(a fresh VARIATION in that family) then a curriculum-AUTHOR step that proposes new rungs to fill
gaps. This is the layer that turns the factory from "run one rung" into "keep building game
content on its own until told to stop."

Charter safety, carried through:
- Only PROVEN families run autonomously (FactoryRunner refuses proven=false — new domains still need
  a supervised first ascent). So this iterates what's proven AND grows a proposal backlog.
- The author is PROPOSE-ONLY: it appends to curriculum.proposals[], NEVER promotes to rungs[] and
  NEVER sets proven=true — a human does that. Proposals are deduped and capped.
- Every artifact is still gated + verified + staged by the factory; nothing auto-promotes to skills.

Single-flight: reuses the ONE FactoryRunner (which owns the loop) and the LoopRunner (for the author
step), one cycle at a time; a forever-busy flag fences external /loop /factory /forever (server.py).
"""

import json
import os
import re
import threading
import time

import agent_loop
import factory as factory_mod

PROPOSALS_JSON_RE = re.compile(r"FACTORY_PROPOSALS_JSON:\s*(\[.*\])", re.DOTALL)
RETRO_JSON_RE = re.compile(r"FACTORY_RETRO_JSON:\s*(\{.*\})", re.DOTALL)
MECHANIC_JSON_RE = re.compile(r"FACTORY_MECHANIC_JSON:\s*(\{.*\})", re.DOTALL)
AUTHOR_MAX_ITER = 6
RETRO_MAX_ITER = 5
MECHANIC_MAX_ITER = 30
MAX_METHOD_LESSONS = 40
MAX_TOOLING_ISSUES = factory_mod.MAX_TOOLING_ISSUES
_BAD_STATUSES = ("FAILED", "UNVERIFIED", "BLOCKED", "error")
# Wait generously ABOVE each sub-runner's OWN internal cap, so a healthy long run is never
# mis-timed-out and its thread never orphaned. A factory iteration = BUILD loop + VERIFY loop
# (each bounded by factory.LOOP_WAIT_CAP) + gate/stage; the author is one loop (bounded by the
# loop's own WALL_CLOCK_CAP). The forever loop primarily waits on the sub-runner's busy/running
# STATE; these caps are only an outer sanity backstop, deliberately above the real worst case.
FACTORY_WAIT_CAP = 2 * factory_mod.LOOP_WAIT_CAP + 20 * 60.0  # ~120 min (real max ~105)
AUTHOR_WAIT_CAP = agent_loop.WALL_CLOCK_CAP + 10 * 60.0  # ~55 min (loop caps itself at 45)
# An unattended cycles=None run self-terminates after this many cycles (a compute backstop; each
# cycle is a full build+verify+author). Pass an explicit `cycles` to go higher.
DEFAULT_UNBOUNDED_CAP = 50
POLL = 1.0
MAX_PROPOSALS_PER_CYCLE = 3
MAX_TOTAL_PROPOSALS = 40
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")

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


class ForeverError(ValueError):
    """Client error — maps to HTTP 400/409."""


def _sanitize_id(raw) -> str:
    s = re.sub(r"[^a-z0-9-]+", "-", str(raw or "").lower()).strip("-")
    return s[:64]


def _parse_proposals(text: str):
    """Parse the LAST FACTORY_PROPOSALS_JSON array, tolerating trailing prose. -> list or []."""
    if not text:
        return []
    m = None
    for m in PROPOSALS_JSON_RE.finditer(text):
        pass
    if m is None:
        return []
    blob = m.group(1).strip()
    for end in range(len(blob), 0, -1):
        if blob[end - 1] != "]":
            continue
        try:
            val = json.loads(blob[:end])
            return val if isinstance(val, list) else []
        except ValueError:
            continue
    return []


def _parse_last_obj(regex, text: str):
    """Parse the LAST <MARKER>: {...} object, tolerating trailing prose. -> dict or {}."""
    if not text:
        return {}
    m = None
    for m in regex.finditer(text):
        pass
    if m is None:
        return {}
    blob = m.group(1).strip()
    for end in range(len(blob), 0, -1):
        if blob[end - 1] != "}":
            continue
        try:
            val = json.loads(blob[:end])
            return val if isinstance(val, dict) else {}
        except ValueError:
            continue
    return {}


class ForeverRunner:
    def __init__(
        self,
        factory_runner,
        loop_runner,
        curriculum_path,
        store_lister,
        sleep=time.sleep,
        learnings_path=None,
        tooling_path=None,
        mechanic_session=None,
        git_run=None,
        narrate=None,
    ):
        self._factory = factory_runner
        self._loop = loop_runner
        self._curriculum_path = curriculum_path
        self._store_lister = store_lister  # () -> [{"id":...}, ...] of staging entries
        self._sleep = sleep
        here = os.path.dirname(os.path.abspath(__file__))
        # Method lessons live beside the plugin's quality learnings (same schema, new bucket).
        self._learnings_path = learnings_path or os.path.join(
            here, "store", "learnings", "factory-methods.json"
        )
        self._tooling_path = tooling_path or os.path.join(
            os.path.dirname(here), "factory", "tooling-issues.json"
        )
        # Hooks (injectable for tests): a fresh mechanic local-tool session per run, and git.
        self._mechanic_session = mechanic_session  # () -> {"schemas","dispatch","session"}
        self._git_run = git_run  # (args:list) -> (code, out); default = mechanic._git
        self._narrate_cb = narrate  # (text, warn) -> None; live Studio Output commentary
        self._last_mechanic_commit = None  # sha eligible for the regression auto-revert
        self._lock = threading.Lock()
        self._busy = False
        self._stop = False
        self._status = {"state": "idle"}

    # -- public --

    def busy(self) -> bool:
        with self._lock:
            return self._busy

    def status(self) -> dict:
        with self._lock:
            return json.loads(json.dumps(self._status))

    def stop(self):
        """Request a graceful stop after the current cycle finishes."""
        with self._lock:
            if self._busy:
                self._stop = True

    def start(self, cycles=None, families=None) -> int:
        if cycles is not None:
            try:
                cycles = int(cycles)
            except (TypeError, ValueError):
                raise ForeverError("cycles must be a number") from None
            if cycles < 1:
                raise ForeverError("cycles must be >= 1")
        if families is not None and not isinstance(families, list):
            raise ForeverError("families must be a list of family names")
        # An unbounded (cycles=None) run gets a compute backstop so it self-terminates unattended.
        effective_cycles = cycles if cycles is not None else DEFAULT_UNBOUNDED_CAP
        with self._lock:
            if self._busy or self._factory.busy() or self._loop.status().get("state") == "running":
                raise ForeverError("a forever/factory/loop run is already active — one at a time")
            self._busy = True
            self._stop = False
            self._status = {
                "state": "running",
                "cycle": 0,
                "cyclesRequested": cycles,
                "cyclesCap": effective_cycles,
                "families": families,
                "proposalsAdded": 0,
                "history": [],
                "startedAt": time.time(),
            }
        threading.Thread(target=self._run, args=(effective_cycles, families), daemon=True).start()
        return 1

    # -- internals --

    def _set(self, **kv):
        with self._lock:
            self._status.update(kv)

    def _finish(self, **kv):
        with self._lock:
            self._status.update(kv)
            self._busy = False
            self._stop = False

    def _read_curriculum(self):
        with open(self._curriculum_path, encoding="utf-8") as fh:
            return json.load(fh)

    def _run(self, cycles, families):
        try:
            self._run_inner(cycles, families)
        except Exception as exc:  # noqa: BLE001 — never leave the loop wedged busy
            self._finish(state="error", error=f"internal forever error: {exc!r}")

    def _run_inner(self, cycles, families):
        proven_families = self._proven_families(families)
        if not proven_families:
            return self._finish(
                state="done",
                stopped="no-proven-families",
                reason="no proven families to cycle (proven=false rungs need supervised first ascents)",
            )
        # A per-run token keeps staging ids unique ACROSS separate forever invocations (both start
        # at done=0, so "-auto-1" alone would collide and overwrite the prior run's entry).
        run_token = _sanitize_id(str(int(self._status.get("startedAt", 0)) % 1000000)) or "0"
        done = 0
        total_added = 0
        prev_status = {}  # family -> last cycle's status (regression detection)
        self._narrate(
            f"forever run started: {cycles} cycle(s), rotation [{', '.join(proven_families)}]"
        )
        while True:
            with self._lock:
                stop_now = self._stop
            if stop_now:
                # NB: _finish acquires the lock, so it must run OUTSIDE the `with` above.
                self._finish(state="done", stopped="requested", cycle=done, proposalsAdded=total_added)
                return
            if done >= cycles:
                break
            fam = proven_families[done % len(proven_families)]
            rung = self._representative_rung(fam)
            if rung is None:  # a family lost its proven rung mid-run — skip it
                done += 1
                continue

            staged_ids = [i.get("id") for i in (self._store_lister() or []) if isinstance(i, dict)]
            hint = (
                f"Prior artifacts already staged: {', '.join(staged_ids) if staged_ids else 'none'}. "
                f"Make a NEW {fam} distinct from those."
            )
            staging_id = _sanitize_id(f"{rung['id']}-auto-{run_token}-{done + 1}")

            self._set(cycle=done + 1, stage="factory", rung=rung["id"], family=fam)
            self._narrate(f"=== cycle {done + 1}/{cycles}: {fam} ({rung['id']}) ===")
            try:
                self._factory.start(rung["id"], variant_hint=hint, staging_id=staging_id)
            except Exception as exc:  # noqa: BLE001 — a busy/refused factory ends the loop cleanly
                return self._finish(state="error", error=f"factory start failed: {exc!r}", cycle=done)
            finished, fres = self._wait_factory()
            if not finished:
                # The generous backstop fired — the factory is orphaned (still driving the bridge).
                # Do NOT start an author loop or the next cycle on top of it; abort so we never
                # double-drive the single-slot bridge. (The orphan finishes on its own internal cap.)
                return self._finish(state="error", error=fres.get("reason"), cycle=done)

            status_now = fres.get("status") or fres.get("state")

            # Regression auto-revert: a mechanic change followed by a same-family PASSED->bad
            # drop gets reverted automatically (the user's step-in guarantee).
            self._maybe_revert_on_regression(prev_status.get(fam), status_now)
            prev_status[fam] = status_now

            # RETRO: bank durable method lessons + detect tooling defects (self-improvement).
            self._set(stage="retro")
            issues = self._run_retro(rung, fam, fres)

            # MECHANIC: the loop repairs its own tooling (full autonomy + auto-revert charter).
            if issues:
                self._set(stage="mechanic")
                self._run_mechanic(issues)

            self._set(stage="author")
            added = self._run_author()
            total_added += added
            if added:
                self._narrate(f"author: +{added} proposal(s) in the backlog")

            with self._lock:
                self._status["proposalsAdded"] = total_added
                self._status.setdefault("history", []).append(
                    {
                        "cycle": done + 1,
                        "rung": rung["id"],
                        "family": fam,
                        "stagingId": staging_id,
                        "status": fres.get("status") or fres.get("state"),
                        "proposalsAdded": added,
                    }
                )
                del self._status["history"][:-20]
            done += 1
        self._finish(state="done", stopped="cycles", cycle=done, proposalsAdded=total_added)

    def _proven_families(self, families):
        """Ordered unique families that have at least one proven rung (optionally filtered).
        With no explicit filter, the curriculum's persistent "focus" list (the user's standing
        rotation directive) is the filter."""
        curriculum = self._read_curriculum()
        if families is None:
            focus = curriculum.get("focus")
            if isinstance(focus, list) and focus:
                families = focus
        out = []
        for rung in curriculum.get("rungs", []):
            fam = rung.get("family")
            if not rung.get("proven") or not fam:
                continue
            if families and fam not in families:
                continue
            if fam not in out:
                out.append(fam)
        return out

    def _representative_rung(self, family):
        curriculum = self._read_curriculum()
        for rung in curriculum.get("rungs", []):
            if rung.get("proven") and rung.get("family") == family:
                return rung
        return None

    def _wait_factory(self):
        """Wait for the factory to reach a terminal state — detected by its BUSY flag flipping
        False (set on every FactoryRunner exit path), NOT a cap shorter than the factory's own
        internal caps. Returns (finished, status). finished=False only if the generous outer
        backstop fires, meaning the factory is orphaned (caller must abort, not proceed)."""
        deadline = time.monotonic() + FACTORY_WAIT_CAP
        while time.monotonic() < deadline:
            st = self._factory.status()
            self._set(factoryStage=st.get("stage"), loopIteration=st.get("loopIteration"))
            if not self._factory.busy():
                return True, st
            self._sleep(POLL)
        return False, {
            "state": "error",
            "reason": f"factory exceeded the {FACTORY_WAIT_CAP / 60:.0f}min backstop — orphaned",
        }

    def _narrate(self, text, warn=False):
        """Live commentary into Studio's Output (best-effort — never breaks the loop)."""
        if self._narrate_cb is None:
            return
        try:
            self._narrate_cb(str(text)[:400], warn)
        except Exception:  # noqa: BLE001
            pass

    def _wait_loop_text(self, prompt, max_iterations, local_tools=None):
        """Start one loop run and wait on the loop's OWN state (bounded by its WALL_CLOCK_CAP),
        not a shorter cap — a backstop that fires early would leave the loop running and kill the
        next cycle's factory.start. -> final text, or None on error/backstop."""
        try:
            if local_tools is not None:
                self._loop.start(prompt, max_iterations=max_iterations, local_tools=local_tools)
            else:
                self._loop.start(prompt, max_iterations=max_iterations)
        except Exception:  # noqa: BLE001
            return None
        deadline = time.monotonic() + AUTHOR_WAIT_CAP
        while time.monotonic() < deadline:
            st = self._loop.status()
            state = st.get("state")
            if state == "done":
                return str(st.get("result") or "")
            if state == "error":
                return None
            self._sleep(POLL)
        # Backstop fired (should not happen — it is above the loop's own cap). Let the loop
        # actually SETTLE before returning, so the next start isn't refused by a running loop.
        settle = time.monotonic() + AUTHOR_WAIT_CAP
        while time.monotonic() < settle and self._loop.status().get("state") == "running":
            self._sleep(POLL)
        return None

    def _run_author(self) -> int:
        """One author loop run: propose new rungs, append the deduped valid ones. Returns count."""
        text = self._wait_loop_text(self._author_prompt(), AUTHOR_MAX_ITER)
        if text is None:
            return 0
        return self._append_proposals(_parse_proposals(text))

    # -- self-improvement: retro (method lessons) + mechanic (tool self-repair) --

    def _run_retro(self, rung, fam, fres):
        """Reflect on the finished cycle: bank durable METHOD lessons and detect TOOLING defects.
        Returns the toolingIssues list (the mechanic's trigger). Never raises."""
        try:
            text = self._wait_loop_text(self._retro_prompt(rung, fam, fres), RETRO_MAX_ITER)
            retro = _parse_last_obj(RETRO_JSON_RE, text or "")
            lessons = _normalize_lessons(retro.get("methodLessons"))
            issues = [
                i for i in (retro.get("toolingIssues") or [])
                if isinstance(i, dict) and i.get("title")
            ]
            n = self._append_method_lessons(lessons)
            self._append_tooling_issues(issues)
            with self._lock:
                self._status["lessonsAdded"] = int(self._status.get("lessonsAdded") or 0) + n
            for lesson in lessons[:2]:
                self._narrate(f"retro lesson [{lesson['tier']}]: {lesson['text']}")
            for issue in issues:
                self._narrate(f"retro: tooling defect filed - {issue.get('title')}", warn=True)
            return issues
        except Exception:  # noqa: BLE001 — retro is best-effort, never kills the cycle
            return []

    def _retro_prompt(self, rung, fam, fres) -> str:
        build = fres.get("build") or {}
        verify = fres.get("verify") or {}
        record = {
            "rung": rung.get("id"),
            "family": fam,
            "status": fres.get("status") or fres.get("state"),
            "reason": fres.get("reason"),
            "buildSteps": build.get("steps"),
            "buildNotes": build.get("notes"),
            "verifyEvidence": verify.get("evidence"),
            "verifyReasons": verify.get("reasons"),
        }
        return (
            "You are the factory RETRO stage - its self-improvement reflex. A build+verify cycle "
            "just finished. The record:\n" + json.dumps(record) + "\n\n"
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
        )

    def _append_method_lessons(self, lessons) -> int:
        """Append deduped tiered method lessons to the factory-methods learnings bucket (same
        schema as the plugin's quality learnings, plus a verification tier per entry). Capped;
        newest survive. Returns how many were added."""
        if not lessons:
            return 0
        try:
            with open(self._learnings_path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            data = {"category": "factory-methods", "seq": 0, "entries": []}
        entries = data.setdefault("entries", [])
        known = {e.get("text") for e in entries if isinstance(e, dict)}
        added = 0
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
        del entries[:-MAX_METHOD_LESSONS]
        os.makedirs(os.path.dirname(self._learnings_path), exist_ok=True)
        with open(self._learnings_path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1)
        return added

    def _append_tooling_issues(self, issues):
        """Append tooling defects to the mechanic's backlog file (shared impl in factory.py)."""
        factory_mod.append_tooling_issues(issues, self._tooling_path)

    def _run_mechanic(self, issues) -> bool:
        """One self-repair run (charter 2026-07-04: FULL autonomy + auto-revert). The mechanic
        gets local repo tools; unproven work is reverted HERE, not trusted."""
        try:
            make = self._mechanic_session
            if make is None:
                import mechanic as mechanic_mod

                make = mechanic_mod.make_session
            tools = make()
            session = tools.get("session")
            self._narrate(
                "mechanic: attempting self-repair of "
                + ", ".join(str(i.get("title")) for i in issues[:3])
            )
            text = self._wait_loop_text(
                self._mechanic_prompt(issues),
                MECHANIC_MAX_ITER,
                local_tools={"schemas": tools["schemas"], "dispatch": tools["dispatch"]},
            )
            verdict = _parse_last_obj(MECHANIC_JSON_RE, text or "")
            fixed = bool(verdict.get("fixed")) and bool(str(verdict.get("proof") or "").strip())
            with self._lock:
                self._status["mechanicRuns"] = int(self._status.get("mechanicRuns") or 0) + 1
            if not fixed:
                # Unproven: discard the run's edits entirely (files back, commits reverted).
                files = session.revert_uncommitted() if session else []
                commits = session.revert_commits() if session else []
                with self._lock:
                    self._status["mechanicLast"] = {
                        "fixed": False,
                        "revertedFiles": files,
                        "revertedCommits": commits,
                    }
                self._narrate(
                    "mechanic: no PROVEN fix - all changes reverted "
                    f"({len(files)} file(s), {len(commits)} commit(s))",
                    warn=True,
                )
                return False
            # Proven but uncommitted work would be unrevertable later — commit it for the audit
            # trail (the mechanic SHOULD have; this is the harness backstop).
            if session and session.touched and not session.commits:
                session.dispatch("git_commit", {
                    "message": f"{issues[0].get('title', 'tooling fix')} (harness-committed)",
                })
            if session and session.commits:
                self._last_mechanic_commit = session.commits[-1]
            with self._lock:
                self._status["mechanicLast"] = {
                    "fixed": True,
                    "files": verdict.get("files"),
                    "commit": self._last_mechanic_commit,
                    "pendingSidecarRestart": bool(verdict.get("pendingSidecarRestart")),
                }
            sha = (self._last_mechanic_commit or "")[:10]
            self._narrate(
                f"mechanic: fix PROVEN ({str(verdict.get('proof') or '')[:120]}) - "
                f"committed {sha or '(no commit)'}"
            )
            return True
        except Exception:  # noqa: BLE001 — the mechanic must never kill the forever loop
            return False

    def _mechanic_prompt(self, issues) -> str:
        return (
            "You are the factory MECHANIC - the self-repair stage. The retro found defects in the "
            "factory's own machinery. Fix the TOOLING, minimally and provably.\n\n"
            "DEFECTS:\n" + json.dumps(issues, indent=1) + "\n\n"
            "You have the normal Studio tools PLUS local repo tools (read_source, search_source, "
            "edit_source, write_source, reload_plugin, run_pytests, git_commit). Layout: plugin "
            "Luau under src/ (tools in src/Tools/), factory prompts+playbooks in "
            "sidecar/factory.py, runtime scripts in runtime/.\n\n"
            "CONTRACT:\n"
            "(1) REPRODUCE the defect first in EDIT mode via the Studio tools - if you cannot, "
            "say so and STOP (never fix blind);\n"
            "(2) make the MINIMAL source edit (edit_source over write_source);\n"
            "(3) reload_plugin so src/ edits go live (sidecar/*.py edits only apply after a "
            "sidecar restart - mark them pendingSidecarRestart instead);\n"
            "(4) PROVE it: re-run the exact repro and show the new behaviour - unproven edits are "
            "AUTO-REVERTED by the harness;\n"
            "(5) run_pytests - every suite must pass;\n"
            "(6) git_commit naming defect + fix.\n"
            "Standing goal: prefer CREATING edit-mode test paths over play-mode ones - playtest "
            "dependence should shrink over time. Never linger in play mode.\n\n"
            "End your FINAL message with ONLY this line:\n"
            'FACTORY_MECHANIC_JSON: {"fixed":true|false,"files":["src/..."],'
            '"proof":"<one sentence: repro before vs after>","pendingSidecarRestart":false}'
        )

    def _maybe_revert_on_regression(self, prev_family_status, status_now):
        """PASSED -> bad in the family right after a mechanic change: revert that change."""
        if self._last_mechanic_commit is None:
            return
        if prev_family_status != "PASSED" or status_now not in _BAD_STATUSES:
            return
        git = self._git_run
        if git is None:
            import mechanic as mechanic_mod

            git = mechanic_mod._git
        sha = self._last_mechanic_commit
        code, _out = git(["revert", "--no-edit", sha])
        with self._lock:
            self._status["mechanicReverted"] = {"commit": sha, "ok": code == 0}
        self._narrate(
            f"regression after a mechanic change - auto-reverted commit {sha[:10]}", warn=True
        )
        self._append_method_lessons(_normalize_lessons([
            f"A mechanic change ({sha[:10]}) was auto-reverted after the next same-family cycle "
            "regressed - re-diagnose from scratch before re-attempting that fix."
        ]))
        self._last_mechanic_commit = None

    def _author_prompt(self) -> str:
        curriculum = self._read_curriculum()
        rungs = curriculum.get("rungs", [])
        proposals = curriculum.get("proposals", [])
        proven = sorted({r.get("family") for r in rungs if r.get("proven") and r.get("family")})
        unproven = sorted(
            {r.get("family") for r in rungs if not r.get("proven") and r.get("family")}
        )
        staged = [i.get("id") for i in (self._store_lister() or []) if isinstance(i, dict)]
        existing_ids = [r.get("id") for r in rungs] + [p.get("id") for p in proposals]
        return (
            "You are the curriculum AUTHOR for an autonomous Roblox game-building factory. Propose "
            "the NEXT things worth building so the factory keeps improving the game across every "
            "domain — weapons, enemies, animations, buildings, environments, GUI, systems, VFX.\n\n"
            f"Proven families (build autonomously today): {', '.join(proven) or 'none'}\n"
            f"Queued families (await a supervised first ascent): {', '.join(unproven) or 'none'}\n"
            f"Already staged this session: {', '.join(staged) if staged else 'none'}\n"
            f"Existing rung/proposal ids (do NOT duplicate): {', '.join(str(i) for i in existing_ids)}\n\n"
            "Propose 1-3 NEW rungs that add the most value — either a fresh variation in a proven "
            "family, or a valuable new buildable thing in an under-covered domain. Each must be "
            "concrete and buildable with the plugin's tools. You do NOT need to inspect the place; "
            "reason from the summary above. This is PROPOSE-ONLY — you are drafting the backlog, not "
            "building anything now.\n\n"
            "End your FINAL message with EXACTLY ONE line, no code fence:\n"
            'FACTORY_PROPOSALS_JSON: [{"id":"<kebab-id>","category":"<combat|npc|environment|gui>",'
            '"family":"<melee-weapon|melee-enemy|animation|building|environment|gui|game-system|...>",'
            '"proven":false,"brief":"<what to build + the visual/behaviour bar>","oracle":"<how VERIFY '
            'proves it>","rationale":"<why this next>"}]'
        )

    def _append_proposals(self, proposals) -> int:
        if not isinstance(proposals, list) or not proposals:
            return 0
        curriculum = self._read_curriculum()
        existing = {r.get("id") for r in curriculum.get("rungs", [])}
        existing |= {p.get("id") for p in curriculum.get("proposals", [])}
        added = 0
        bucket = curriculum.setdefault("proposals", [])
        for prop in proposals:
            if added >= MAX_PROPOSALS_PER_CYCLE or len(bucket) >= MAX_TOTAL_PROPOSALS:
                break
            if not isinstance(prop, dict):
                continue
            pid = _sanitize_id(prop.get("id"))
            if not pid or not _ID_RE.match(pid) or pid in existing:
                continue
            if not prop.get("brief") or not prop.get("family"):
                continue
            # PROPOSE-ONLY: force proven=false + tag provenance no matter what the model emitted.
            clean = {
                "id": pid,
                "category": str(prop.get("category") or "")[:40],
                "family": str(prop.get("family"))[:40],
                "proven": False,
                "brief": str(prop.get("brief"))[:600],
                "oracle": str(prop.get("oracle") or "")[:600],
                "rationale": str(prop.get("rationale") or "")[:400],
                "proposedBy": "forever-author",
            }
            bucket.append(clean)
            existing.add(pid)
            added += 1
        if added:
            self._write_curriculum(curriculum)
        return added

    def _write_curriculum(self, curriculum):
        tmp = self._curriculum_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(curriculum, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, self._curriculum_path)
