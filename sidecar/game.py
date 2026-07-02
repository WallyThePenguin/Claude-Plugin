"""GameSync file IO for the Studio Agent sidecar (the sidecar owns filesystem + git).

game_pull banks the place's authored SCRIPTS as git-versioned files under game/ (the path-C
"code-first" first increment): the plugin collects sources + a manifest and POSTs them here;
this module writes them and AUTO-COMMITS — every pull is a git commit, so every synced state is
recoverable forever (the skeptic panel's lost-update fix: the file at the pull commit IS the
baseHash-era text).

Safety: refuses paths escaping game/, refuses when game/ is already git-dirty (a pull must never
clobber uncommitted file edits — commit first).
"""

import os
import subprocess

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME_DIR = os.path.join(REPO_DIR, "game")


class GameError(ValueError):
    """A client error — maps to HTTP 400."""


def _safe_join(relpath: str) -> str:
    """Resolve a manifest relpath under game/, refusing escapes and absolute paths."""
    if not isinstance(relpath, str) or relpath == "":
        raise GameError("empty relpath")
    norm = os.path.normpath(relpath).replace("\\", "/")
    if norm.startswith("/") or norm.startswith("..") or ":" in norm:
        raise GameError(f"relpath escapes game/: {relpath!r}")
    full = os.path.normpath(os.path.join(GAME_DIR, norm))
    if not (full == GAME_DIR or full.startswith(GAME_DIR + os.sep)):
        raise GameError(f"relpath escapes game/: {relpath!r}")
    return full


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=REPO_DIR, capture_output=True, text=True, timeout=30
    )


def game_dirty() -> bool:
    """True when game/ has uncommitted changes (staged or not)."""
    res = _git("status", "--porcelain", "--", "game/")
    return res.returncode == 0 and res.stdout.strip() != ""


def write_game(files: dict, manifest: dict, message: str) -> dict:
    """Write the pulled files + manifest under game/ and commit. Returns {written, commit}."""
    if not isinstance(files, dict) or not isinstance(manifest, dict):
        raise GameError("files and manifest must be objects")
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

    import json as _json

    for full, source in resolved.items():
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(source)
    manifest_path = os.path.join(GAME_DIR, "sync-manifest.json")
    os.makedirs(GAME_DIR, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as fh:
        _json.dump(manifest, fh, ensure_ascii=False, indent=1, sort_keys=True)

    add = _git("add", "--", "game/")
    if add.returncode != 0:
        raise GameError("git add failed: " + add.stderr.strip())
    status = _git("status", "--porcelain", "--", "game/")
    if status.stdout.strip() == "":
        return {"written": len(resolved), "commit": None, "note": "no changes vs the last pull"}
    msg = message if isinstance(message, str) and message.strip() != "" else "chore(game): pull"
    commit = _git(
        "commit",
        "-m",
        msg + "\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>",
        "--",
        "game/",
    )
    if commit.returncode != 0:
        raise GameError("git commit failed: " + commit.stderr.strip())
    head = _git("rev-parse", "--short", "HEAD")
    return {"written": len(resolved), "commit": head.stdout.strip()}
