"""Exemplar corpus reader for the Studio Agent vision sidecar.

Serves curated reference images per rubric category for evaluate's visual (calibration) grading.
Reads sidecar/exemplars/manifest.json + the referenced PNGs; returns metadata (+ base64 image when
requested). The manifest IS the store; scripts/validate_exemplars.py enforces clean licensing before
anything lands here. Pure standard library.
"""

from __future__ import annotations

import base64
import json
import os

_PUBLIC_FIELDS = ("id", "category", "caption", "tier", "license", "source", "criterion_id")


def exemplars_dir() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "exemplars")


def manifest_path() -> str:
    return os.path.join(exemplars_dir(), "manifest.json")


def load_manifest():
    """The manifest's exemplar list, or [] if missing/unreadable/malformed."""
    try:
        with open(manifest_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    exemplars = data.get("exemplars") if isinstance(data, dict) else None
    return exemplars if isinstance(exemplars, list) else []


def exemplars_for(category, want_b64=False):
    """Manifest entries for `category` as dicts of the public fields (+ base64 `image` when want_b64
    and the file reads). Entries whose file is missing are skipped when want_b64."""
    out = []
    for ex in load_manifest():
        if not isinstance(ex, dict) or ex.get("category") != category:
            continue
        entry = {k: ex.get(k) for k in _PUBLIC_FIELDS}
        if want_b64:
            rel = ex.get("file")
            if not isinstance(rel, str):
                continue
            try:
                with open(os.path.join(exemplars_dir(), rel), "rb") as f:
                    entry["image"] = base64.b64encode(f.read()).decode("ascii")
            except OSError:
                continue
        out.append(entry)
    return out
