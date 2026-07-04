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
AUTHOR_MAX_ITER = 6
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


class ForeverRunner:
    def __init__(self, factory_runner, loop_runner, curriculum_path, store_lister, sleep=time.sleep):
        self._factory = factory_runner
        self._loop = loop_runner
        self._curriculum_path = curriculum_path
        self._store_lister = store_lister  # () -> [{"id":...}, ...] of staging entries
        self._sleep = sleep
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

            self._set(stage="author")
            added = self._run_author()
            total_added += added

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

    def _run_author(self) -> int:
        """One author loop run: propose new rungs, append the deduped valid ones. Returns count."""
        prompt = self._author_prompt()
        try:
            self._loop.start(prompt, max_iterations=AUTHOR_MAX_ITER)
        except Exception:  # noqa: BLE001
            return 0
        # Wait on the loop's OWN state (bounded by its WALL_CLOCK_CAP), not a shorter cap — a
        # backstop that fires early would leave the author loop running and kill the next cycle's
        # factory.start (loop still marked running).
        deadline = time.monotonic() + AUTHOR_WAIT_CAP
        text = None
        while time.monotonic() < deadline:
            st = self._loop.status()
            state = st.get("state")
            if state == "done":
                text = str(st.get("result") or "")
                break
            if state == "error":
                return 0
            self._sleep(POLL)
        if text is None:
            # Backstop fired (should not happen — it is above the loop's own cap). Let the loop
            # actually SETTLE before returning, so the next cycle's factory.start isn't refused by
            # a still-running loop.
            settle = time.monotonic() + AUTHOR_WAIT_CAP
            while time.monotonic() < settle and self._loop.status().get("state") == "running":
                self._sleep(POLL)
            return 0
        return self._append_proposals(_parse_proposals(text))

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
