"""File-backed knowledge store for the Studio Agent sidecar.

Storage layout: sidecar/store/<kind>/<id>.json — GIT-TRACKED, so every learning, skill, and
staged artifact is versioned, diffable, and revertable. This is the unbounded half of the
knowledge system: the plugin keeps small always-on caches (plugin settings), while everything
ever learned lives here (the skeptic-panel mandate: artifact capital under version control).

Kinds are allowlisted; ids are sanitized to [a-z0-9-]{1,64} so path traversal is impossible by
construction. Writes are atomic (tmp file + os.replace).
"""

import json
import os
import re

STORE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store")

KINDS = ("learnings", "skills", "staging")

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


class StoreError(ValueError):
    """A client error (bad kind / bad id) — maps to HTTP 400."""


def _validate(kind: str, item_id: str | None = None) -> str:
    if kind not in KINDS:
        raise StoreError(f"unknown store kind '{kind}' (use one of {', '.join(KINDS)})")
    kind_dir = os.path.join(STORE_DIR, kind)
    if item_id is not None and not _ID_RE.match(item_id):
        raise StoreError("id must match [a-z0-9][a-z0-9-]{0,63}")
    return kind_dir


def _path(kind: str, item_id: str) -> str:
    kind_dir = _validate(kind, item_id)
    return os.path.join(kind_dir, f"{item_id}.json")


def list_items(kind: str) -> list:
    """[{id, size, mtime}] for every item of `kind`, newest-modified first."""
    kind_dir = _validate(kind)
    if not os.path.isdir(kind_dir):
        return []
    items = []
    for name in os.listdir(kind_dir):
        if not name.endswith(".json"):
            continue
        item_id = name[: -len(".json")]
        if not _ID_RE.match(item_id):
            continue
        full = os.path.join(kind_dir, name)
        try:
            stat = os.stat(full)
        except OSError:
            continue
        items.append({"id": item_id, "size": stat.st_size, "mtime": stat.st_mtime})
    items.sort(key=lambda i: i["mtime"], reverse=True)
    return items


def read_item(kind: str, item_id: str):
    """The parsed JSON body, or None when absent."""
    path = _path(kind, item_id)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_item(kind: str, item_id: str, body) -> None:
    """Atomically write `body` (any JSON-serializable value) as the item."""
    path = _path(kind, item_id)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(body, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def delete_item(kind: str, item_id: str) -> bool:
    """Remove the item; True when it existed."""
    path = _path(kind, item_id)
    if not os.path.isfile(path):
        return False
    os.remove(path)
    return True
