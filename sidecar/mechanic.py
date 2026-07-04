"""mechanic.py — LOCAL tools for the factory's self-repair (MECHANIC) runs.

The mechanic is a loop run whose agent gets, in addition to the normal Studio bridge tools,
these SIDECAR-SIDE tools: read/edit the repo's own source (plugin Luau, factory prompts),
hot-reload the plugin, run the python test suites, and commit its work. Charter (2026-07-04,
user-approved): FULL autonomy — no protected paths — balanced entirely by revertibility:
- every mechanic commit is tagged "[mechanic]" (one `git revert` to undo);
- the harness (forever.py) auto-reverts uncommitted edits when a run ends without a proven
  fix, and auto-reverts the last mechanic commit when the next same-family cycle regresses.

A session object tracks touched files + commits so the harness can enforce that contract.
"""

import json
import os
import subprocess
import time
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_READ = 60_000  # chars per read_source
MAX_TEST_OUTPUT = 4_000
TEST_SUITES = ["test_factory.py", "test_forever.py", "test_agent_loop.py", "test_server.py"]


def _safe_path(rel: str):
    """Resolve a repo-relative path, refusing escapes ('..' out of the repo). -> (abs, err)."""
    if not isinstance(rel, str) or not rel.strip():
        return None, "path is required"
    p = os.path.abspath(os.path.join(REPO_ROOT, rel.strip()))
    if not (p == REPO_ROOT or p.startswith(REPO_ROOT + os.sep)):
        return None, f"path escapes the repo: {rel}"
    return p, None


def _git(args, cwd=REPO_ROOT):
    """Run git; -> (code, output). Never raises."""
    try:
        proc = subprocess.run(
            ["git"] + list(args), cwd=cwd, capture_output=True, text=True, timeout=60
        )
        return proc.returncode, (proc.stdout + proc.stderr).strip()
    except Exception as exc:  # noqa: BLE001
        return 1, f"git failed: {exc!r}"


class MechanicSession:
    """One mechanic run's local-tool surface + audit state (touched files, commits)."""

    def __init__(self, sidecar_url="http://127.0.0.1:8389", git_run=_git, repo_root=REPO_ROOT):
        self.sidecar_url = sidecar_url.rstrip("/")
        self.git_run = git_run
        self.repo_root = repo_root
        self.touched = []  # repo-relative paths written this run
        self.commits = []  # shas committed this run

    # -- harness enforcement --

    def revert_uncommitted(self):
        """Discard uncommitted changes to every touched file (the unproven-fix teardown)."""
        reverted = []
        for rel in self.touched:
            code, _ = self.git_run(["checkout", "--", rel])
            if code == 0:
                reverted.append(rel)
        return reverted

    def revert_commits(self):
        """Revert this run's commits, newest first. Returns the reverted shas."""
        reverted = []
        for sha in reversed(self.commits):
            code, _ = self.git_run(["revert", "--no-edit", sha])
            if code == 0:
                reverted.append(sha)
        return reverted

    # -- the local tools --

    def schemas(self):
        s = lambda **props: {"type": "object", "properties": props}  # noqa: E731
        txt = lambda d: {"type": "string", "description": d}  # noqa: E731
        return [
            {
                "name": "read_source",
                "description": "Read a repo file (plugin Luau under src/, factory prompts in "
                "sidecar/factory.py, runtime/ scripts...). Input: {path} repo-relative.",
                "input_schema": s(path=txt("repo-relative path, e.g. src/ToolFactory.luau")),
            },
            {
                "name": "search_source",
                "description": "Search repo source files for a regex. Input: {pattern, subdir?}. "
                "Returns file:line matches (capped).",
                "input_schema": s(
                    pattern=txt("regex"), subdir=txt("limit to a subdir, e.g. src or sidecar")
                ),
            },
            {
                "name": "edit_source",
                "description": "Targeted edit of a repo file: replace EXACTLY ONE occurrence of "
                "`old` with `new`. Fails if old is missing or ambiguous. Prefer this over "
                "write_source. Input: {path, old, new}.",
                "input_schema": s(path=txt("repo-relative path"), old=txt("exact text to replace"),
                                  new=txt("replacement text")),
            },
            {
                "name": "write_source",
                "description": "Write/overwrite a whole repo file (for NEW files; prefer "
                "edit_source for existing ones). Input: {path, content}.",
                "input_schema": s(path=txt("repo-relative path"), content=txt("full file content")),
            },
            {
                "name": "reload_plugin",
                "description": "Hot-reload the Studio plugin so src/ edits take effect (edits to "
                "sidecar/*.py need a sidecar restart instead - note those in your report). No input.",
                "input_schema": s(),
            },
            {
                "name": "run_pytests",
                "description": "Run the sidecar python test suites (factory/forever/agent_loop/"
                "server). Input: {suite?} one filename to run just it. Returns the tail.",
                "input_schema": s(suite=txt("optional: one of " + ", ".join(TEST_SUITES))),
            },
            {
                "name": "git_commit",
                "description": "Commit ALL current repo changes as one '[mechanic]' commit. "
                "Only commit AFTER your live re-repro PROVES the fix. Input: {message}.",
                "input_schema": s(message=txt("what was broken + what the fix does")),
            },
        ]

    def dispatch(self, name, args):
        """-> (text, is_error). Total: never raises."""
        try:
            return self._dispatch(name, args if isinstance(args, dict) else {})
        except Exception as exc:  # noqa: BLE001
            return f"{name}: {exc!r}", True

    def _dispatch(self, name, args):
        if name == "read_source":
            p, err = _safe_path(args.get("path"))
            if err:
                return "read_source: " + err, True
            if not os.path.isfile(p):
                return f"read_source: no such file: {args.get('path')}", True
            with open(p, encoding="utf-8", errors="replace") as fh:
                content = fh.read()
            if len(content) > MAX_READ:
                content = content[:MAX_READ] + f"\n... [truncated at {MAX_READ} chars]"
            return content, False

        if name == "search_source":
            import re as _re

            try:
                rx = _re.compile(str(args.get("pattern") or ""))
            except _re.error as exc:
                return f"search_source: bad regex: {exc}", True
            base, err = _safe_path(args.get("subdir") or ".")
            if err:
                return "search_source: " + err, True
            hits = []
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [
                    d for d in dirnames
                    if d not in (".git", "__pycache__", "node_modules", "dist", "build", "loops")
                ]
                for fn in filenames:
                    if not fn.endswith((".luau", ".py", ".json", ".md", ".ps1")):
                        continue
                    fp = os.path.join(dirpath, fn)
                    try:
                        with open(fp, encoding="utf-8", errors="replace") as fh:
                            for i, line in enumerate(fh, 1):
                                if rx.search(line):
                                    rel = os.path.relpath(fp, self.repo_root)
                                    hits.append(f"{rel}:{i}: {line.rstrip()[:200]}")
                                    if len(hits) >= 60:
                                        return "\n".join(hits) + "\n... [capped at 60]", False
                    except OSError:
                        continue
            return "\n".join(hits) if hits else "no matches", False

        if name == "edit_source":
            p, err = _safe_path(args.get("path"))
            if err:
                return "edit_source: " + err, True
            if not os.path.isfile(p):
                return f"edit_source: no such file: {args.get('path')}", True
            old, new = str(args.get("old") or ""), str(args.get("new") or "")
            if not old:
                return "edit_source: `old` is required", True
            with open(p, encoding="utf-8") as fh:
                content = fh.read()
            n = content.count(old)
            if n == 0:
                return "edit_source: `old` not found (must match EXACTLY, incl. whitespace)", True
            if n > 1:
                return f"edit_source: `old` is ambiguous ({n} occurrences) - add context", True
            with open(p, "w", encoding="utf-8", newline="") as fh:
                fh.write(content.replace(old, new, 1))
            rel = os.path.relpath(p, self.repo_root)
            if rel not in self.touched:
                self.touched.append(rel)
            return f"edit_source: {rel} updated", False

        if name == "write_source":
            p, err = _safe_path(args.get("path"))
            if err:
                return "write_source: " + err, True
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="") as fh:
                fh.write(str(args.get("content") or ""))
            rel = os.path.relpath(p, self.repo_root)
            if rel not in self.touched:
                self.touched.append(rel)
            return f"write_source: {rel} written", False

        if name == "reload_plugin":
            try:
                req = urllib.request.Request(
                    self.sidecar_url + "/reload", b"{}", {"Content-Type": "application/json"}
                )
                rid = json.load(urllib.request.urlopen(req, timeout=10)).get("id")
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    res = json.load(urllib.request.urlopen(
                        self.sidecar_url + f"/reload/result?id={rid}", timeout=10
                    ))
                    if "ok" in res:
                        if res.get("ok"):
                            return "reload ok - src/ edits are live", False
                        return "reload FAILED: " + str(res.get("error")), True
                    time.sleep(0.5)
                return "reload timed out (is Studio open with the bridge active?)", True
            except Exception as exc:  # noqa: BLE001
                return f"reload_plugin: {exc!r}", True

        if name == "run_pytests":
            suites = [args["suite"]] if args.get("suite") in TEST_SUITES else TEST_SUITES
            out = []
            failed = False
            for suite in suites:
                try:
                    proc = subprocess.run(
                        ["python", suite], cwd=os.path.join(self.repo_root, "sidecar"),
                        capture_output=True, text=True, timeout=300,
                    )
                    tail = (proc.stdout + proc.stderr)[-MAX_TEST_OUTPUT // len(suites):]
                    out.append(f"== {suite} (exit {proc.returncode}) ==\n{tail}")
                    failed = failed or proc.returncode != 0
                except Exception as exc:  # noqa: BLE001
                    out.append(f"== {suite} CRASHED: {exc!r} ==")
                    failed = True
            return "\n".join(out), failed

        if name == "git_commit":
            msg = str(args.get("message") or "").strip()
            if not msg:
                return "git_commit: message is required", True
            code, out = self.git_run(["add", "-A"])
            if code != 0:
                return "git_commit (add): " + out, True
            code, out = self.git_run(["commit", "-m", "[mechanic] " + msg])
            if code != 0:
                return "git_commit: " + out, True
            code, sha = self.git_run(["rev-parse", "HEAD"])
            if code == 0 and sha:
                self.commits.append(sha.strip())
            return f"committed {sha.strip()[:10]} - revertible via git revert", False

        return f"unknown local tool: {name}", True


def make_session(sidecar_url="http://127.0.0.1:8389"):
    """The forever loop's hook: a fresh session per mechanic run."""
    s = MechanicSession(sidecar_url=sidecar_url)
    return {
        "schemas": s.schemas(),
        "dispatch": s.dispatch,
        "session": s,
    }
