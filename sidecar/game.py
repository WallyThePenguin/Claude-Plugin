"""GameSync file IO for the Studio Agent sidecar (the sidecar owns filesystem + git).

game_pull banks the place's authored SCRIPTS as git-versioned files under game/ (the path-C
"code-first" first increment): the plugin collects sources + a manifest and POSTs them here;
this module writes them and AUTO-COMMITS — every pull is a git commit, so every synced state is
recoverable forever (the skeptic panel's lost-update fix: the file at the pull commit IS the
baseHash-era text).

Safety (review-hardened, 2026-07-02):
- single-writer LOCK around the whole check->write->commit sequence (ThreadingHTTPServer);
- refuses when game/ is git-dirty, FAILING CLOSED when git itself errors;
- refuses paths escaping (or equal to) game/;
- prunes ORPHANS (files absent from the pull = renamed/deleted in Studio) so the tree never
  drifts from the manifest — scoped pulls merge the manifest and prune only inside their scope;
- any mid-write failure or commit failure ROLLS game/ back to HEAD (verifiably clean at entry),
  so a failed pull can never wedge the next one.
"""

import json
import os
import subprocess
import threading

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME_DIR = os.path.join(REPO_DIR, "game")

_WRITE_LOCK = threading.Lock()


class GameError(ValueError):
    """A client error — maps to HTTP 400."""


def _safe_join(relpath: str) -> str:
    """Resolve a manifest relpath STRICTLY under game/ (never game/ itself)."""
    if not isinstance(relpath, str) or relpath == "":
        raise GameError("empty relpath")
    norm = os.path.normpath(relpath).replace("\\", "/")
    if norm.startswith("/") or norm.startswith("..") or ":" in norm:
        raise GameError(f"relpath escapes game/: {relpath!r}")
    full = os.path.normpath(os.path.join(GAME_DIR, norm))
    if not full.startswith(GAME_DIR + os.sep):
        raise GameError(f"relpath escapes game/: {relpath!r}")
    return full


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=REPO_DIR, capture_output=True, text=True, timeout=30
    )


def game_dirty() -> bool:
    """True when game/ has uncommitted changes (staged or not).

    Raises GameError when git itself fails: an unreadable status must fail CLOSED,
    never be treated as "clean" (that would let a pull clobber uncommitted edits).
    """
    res = _git("status", "--porcelain", "--", "game/")
    if res.returncode != 0:
        raise GameError(
            "git status failed — refusing to pull (cannot prove game/ is clean): "
            + res.stderr.strip()
        )
    return res.stdout.strip() != ""


def _rollback_game() -> None:
    """Restore game/ to HEAD. Safe because write_game verifies game/ is clean at entry."""
    _git("reset", "-q", "--", "game/")
    _git("checkout", "-q", "--", "game/")
    _git("clean", "-qfd", "--", "game/")


def _load_manifest() -> dict:
    path = os.path.join(GAME_DIR, "sync-manifest.json")
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (ValueError, OSError):
        return {}


def read_game() -> dict:
    """The banked game files + manifest, for game_push: {files: {relpath: source}, manifest}."""
    src_dir = os.path.join(GAME_DIR, "src")
    files = {}
    if os.path.isdir(src_dir):
        for dirpath, _dirs, names in os.walk(src_dir):
            for name in names:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, GAME_DIR).replace(os.sep, "/")
                with open(full, "r", encoding="utf-8") as fh:
                    files[rel] = fh.read()
    return {"files": files, "manifest": _load_manifest()}


def write_game(files: dict, manifest: dict, message: str, scope: str = None) -> dict:
    """Write the pulled files + manifest under game/ and commit.

    scope: None for a FULL pull (the incoming manifest is authoritative; orphans anywhere under
    game/src are pruned). For a SCOPED pull, the relpath prefix that was pulled (e.g.
    "src/ServerScriptService") — the manifest is MERGED (entries outside the scope survive) and
    orphan pruning is restricted to the scope.

    Returns {written, removed, commit}.
    """
    with _WRITE_LOCK:
        return _write_game_locked(files, manifest, message, scope)


def _write_game_locked(files: dict, manifest: dict, message: str, scope) -> dict:
    if not isinstance(files, dict) or not isinstance(manifest, dict):
        raise GameError("files and manifest must be objects")
    if scope is not None and (not isinstance(scope, str) or not scope.startswith("src/")):
        raise GameError("scope must be a relpath prefix under src/")
    if game_dirty():
        raise GameError(
            "game/ has uncommitted changes — commit (or discard) them before pulling, "
            "so a pull can never clobber file edits"
        )
    # Validate every path BEFORE writing anything (no partial writes on a bad path).
    resolved = {}
    for relpath, source in files.items():
        if not isinstance(source, str):
            raise GameError(f"source for {relpath!r} must be a string")
        resolved[_safe_join(relpath)] = source

    # Scoped pulls merge into the existing manifest: keep entries outside the scope, replace
    # everything inside it with the incoming set (so in-scope deletions still fall out).
    if scope is not None:
        merged = {
            rel: entry
            for rel, entry in _load_manifest().items()
            if not str(rel).startswith(scope)
        }
        merged.update(manifest)
        manifest = merged

    manifest_path = os.path.join(GAME_DIR, "sync-manifest.json")
    removed = []
    try:
        for full, source in resolved.items():
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(source)
        os.makedirs(GAME_DIR, exist_ok=True)
        with open(manifest_path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=1, sort_keys=True)

        # Prune orphans: on-disk files under the pruning root that this pull (or, for scoped
        # pulls, the merged manifest) no longer accounts for — a script renamed or deleted in
        # Studio must not haunt the tree forever ("the manifest is the source of truth").
        prune_root = os.path.normpath(
            os.path.join(GAME_DIR, scope) if scope is not None else os.path.join(GAME_DIR, "src")
        )
        keep = set(resolved)
        if scope is not None:
            # Out-of-scope files survive by location; in-scope survivors are the incoming set.
            keep |= {_safe_join(rel) for rel in manifest if not str(rel).startswith(scope)}
        if os.path.isdir(prune_root):
            for dirpath, _dirs, names in os.walk(prune_root, topdown=False):
                for name in names:
                    full = os.path.normpath(os.path.join(dirpath, name))
                    if full not in keep:
                        os.remove(full)
                        removed.append(os.path.relpath(full, GAME_DIR).replace(os.sep, "/"))
                if not os.listdir(dirpath):
                    os.rmdir(dirpath)
    except OSError as exc:
        _rollback_game()
        raise GameError(f"filesystem write failed (game/ rolled back to HEAD): {exc}") from exc

    add = _git("add", "--", "game/")
    if add.returncode != 0:
        _rollback_game()
        raise GameError("git add failed (game/ rolled back): " + add.stderr.strip())
    status = _git("status", "--porcelain", "--", "game/")
    if status.stdout.strip() == "":
        return {
            "written": len(resolved),
            "removed": removed,
            "commit": None,
            "note": "no changes vs the last pull",
        }
    msg = message if isinstance(message, str) and message.strip() != "" else "chore(game): pull"
    commit = _git(
        "commit",
        "-m",
        msg + "\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>",
        "--",
        "game/",
    )
    if commit.returncode != 0:
        _rollback_game()
        raise GameError("git commit failed (game/ rolled back): " + commit.stderr.strip())
    head = _git("rev-parse", "--short", "HEAD")
    return {"written": len(resolved), "removed": removed, "commit": head.stdout.strip()}
