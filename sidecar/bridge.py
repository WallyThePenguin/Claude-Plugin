"""Dev-bridge state for the Studio Agent sidecar: a thread-safe in-memory command queue (single slot,
single-flight to match the agent loop), a results map, and the latest pushed Output logs. Pure stdlib."""

import threading


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

    def get_result(self, command_id: int):
        with self._lock:
            return self._results.get(int(command_id))

    def set_logs(self, lines: list):
        with self._lock:
            self._logs = lines or []

    def get_logs(self) -> list:
        with self._lock:
            return list(self._logs)

    def request_reload(self) -> int:
        """Flag a reload (separate from the command queue). Returns its id."""
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
