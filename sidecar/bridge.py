"""Dev-bridge state for the Studio Agent sidecar: a thread-safe in-memory command queue (single slot,
single-flight to match the agent loop), a results map, and the latest pushed Output logs, plus a single-slot hot-reload flag + reload-result map, plus a single-slot playtest command channel + result map, plus a per-session archive of run-mode oracle-twin envelopes (the sidecar-witnessed evidence channel for /play/twins). Pure stdlib."""

import json
import threading

# Memory bound on the twin archive: drop-oldest past this many envelopes per session.
TWIN_CAP = 200


class Store:
    def __init__(self):
        self._lock = threading.Lock()
        self._counter = 0
        self._pending = None  # the one queued command, or None
        self._results = {}     # id -> result dict
        self._logs = []        # latest pushed log entries
        self._reload = None       # {"id": N} when a reload is requested, else None
        self._reload_counter = 0
        self._reload_results = {}  # reload id -> result dict
        self._play = None       # the one queued play command, or None
        self._play_counter = 0
        self._play_results = {}  # play command id -> result dict
        # Twin archive (SP2d follow-up): every play-channel result whose command was the
        # "oracle" verb gets its envelope archived, keyed by play SESSION (a counter bumped
        # on each play "start"). Only the LATEST session is kept — /play/twins serves it.
        self._twin_session = 0
        self._twin_active = False   # start seen without a later stop
        self._twins = []            # envelope dicts, arrival order, latest session only
        self._twin_dropped = 0      # envelopes evicted by TWIN_CAP this session
        self._twin_skipped = 0      # malformed oracle results skipped this session
        self._twin_oracle_ids = set()  # play ids (this session) whose cmd was "oracle"

    def submit(self, command: dict) -> int:
        """Queue a command (overwriting any unclaimed one — single-flight). Returns its id."""
        with self._lock:
            self._counter += 1
            cmd = dict(command)
            cmd["id"] = self._counter
            self._pending = cmd
            return self._counter

    def take_pending(self):
        """Return the queued command and clear the slot, or None if empty."""
        with self._lock:
            cmd = self._pending
            self._pending = None
            return cmd

    def put_result(self, command_id: int, result: dict):
        with self._lock:
            self._results[int(command_id)] = result
            # Bounded: raw-mode results can be multi-MB (base64 captures) and describe results
            # carry the proxy key — never let them pin sidecar RAM for the process lifetime.
            while len(self._results) > 50:
                del self._results[min(self._results)]

    def get_result(self, command_id: int):
        with self._lock:
            return self._results.get(int(command_id))

    def pop_result(self, command_id: int):
        """Take a result and REMOVE it (the loop runner's consume path — keeps big raw results
        and the key-bearing describe result out of the long-lived map)."""
        with self._lock:
            return self._results.pop(int(command_id), None)

    def requeue(self, command: dict):
        """Put a taken command back in the slot unchanged (id preserved)."""
        with self._lock:
            self._pending = command

    def set_logs(self, lines: list):
        with self._lock:
            self._logs = lines or []

    def get_logs(self) -> list:
        with self._lock:
            return list(self._logs)

    def request_reload(self) -> int:
        """Flag a reload (separate from the command queue), overwriting any unclaimed one — single-flight. Returns its id."""
        with self._lock:
            self._reload_counter += 1
            self._reload = {"id": self._reload_counter}
            return self._reload_counter

    def take_reload(self):
        """Return the pending reload request and clear it, or None."""
        with self._lock:
            r = self._reload
            self._reload = None
            return r

    def put_reload_result(self, reload_id: int, result: dict):
        with self._lock:
            self._reload_results[int(reload_id)] = result

    def get_reload_result(self, reload_id: int):
        with self._lock:
            return self._reload_results.get(int(reload_id))

    def play_submit(self, command: dict) -> int:
        """Queue a play command (its own single-slot channel, separate from /agent). Returns its id.

        Session bookkeeping for the twin archive: "start" opens a new session (and resets the
        archive — only the latest session is served), "stop" marks it inactive, and "oracle"
        ids are remembered so their results can be archived on arrival."""
        with self._lock:
            self._play_counter += 1
            cmd = dict(command)
            cmd["id"] = self._play_counter
            self._play = cmd
            verb = cmd.get("cmd")
            if verb == "start":
                self._twin_session += 1
                self._twin_active = True
                self._twins = []
                self._twin_dropped = 0
                self._twin_skipped = 0
                self._twin_oracle_ids = set()  # late results from a prior session are ignored
            elif verb == "stop":
                self._twin_active = False
            elif verb == "oracle":
                self._twin_oracle_ids.add(self._play_counter)
            return self._play_counter

    def play_take_pending(self):
        with self._lock:
            cmd = self._play
            self._play = None
            return cmd

    def play_put_result(self, command_id: int, result: dict):
        with self._lock:
            cid = int(command_id)
            self._play_results[cid] = result
            if cid not in self._twin_oracle_ids:
                return
            self._twin_oracle_ids.discard(cid)
            # The injected run-mode server JSON-encodes the envelope into result.result; tolerate
            # an already-decoded object too. Anything else (error strings like "oracle: bad arg",
            # ok=false plumbing failures) is skipped silently but counted.
            env = result.get("result") if isinstance(result, dict) else None
            if isinstance(env, str):
                try:
                    env = json.loads(env)
                except ValueError:
                    env = None
            if isinstance(env, dict):
                self._twins.append(env)
                if len(self._twins) > TWIN_CAP:
                    del self._twins[0]  # drop-oldest, memory-bounded
                    self._twin_dropped += 1
            else:
                self._twin_skipped += 1

    def play_get_result(self, command_id: int):
        with self._lock:
            return self._play_results.get(int(command_id))

    def play_twins(self) -> dict:
        """The latest play session's archived oracle-twin envelopes (arrival order).

        Shape (the INTER-AGENT CONTRACT — the Luau oracle_suite merge consumes this verbatim):
        {"session": N, "active": bool, "twins": [envelopes]} + "dropped"/"skipped" when nonzero.
        Empty state: {"session": 0, "active": false, "twins": []}."""
        with self._lock:
            payload = {
                "session": self._twin_session,
                "active": self._twin_active,
                "twins": list(self._twins),
            }
            if self._twin_dropped:
                payload["dropped"] = self._twin_dropped
            if self._twin_skipped:
                payload["skipped"] = self._twin_skipped
            return payload
