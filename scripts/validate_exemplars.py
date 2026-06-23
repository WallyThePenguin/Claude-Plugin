"""Stdlib validator for the exemplar manifest (sidecar/exemplars/manifest.json).

Enforces: unique ids; category matches a known rubric module; file exists under exemplars/; license in
{own, official, cc0} (copyrighted is NEVER storable); optional criterion_id resolves to a real criterion
of that category; optional tier in {baseline, good, exceptional}.
"""
import glob
import json
import os
import sys

LICENSES = {"own", "official", "cc0"}
TIERS = {"baseline", "good", "exceptional"}
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXEMPLARS_DIR = os.path.join(REPO, "sidecar", "exemplars")
RUBRICS_DIR = os.path.join(REPO, "docs", "superpowers", "rubrics")


def known_criteria():
    """{category: set(criterion_id)} from docs/superpowers/rubrics/*.rubric.json."""
    out = {}
    for path in glob.glob(os.path.join(RUBRICS_DIR, "*.rubric.json")):
        try:
            with open(path, encoding="utf-8") as f:
                r = json.load(f)
        except (OSError, ValueError):
            continue
        module = r.get("module")
        if isinstance(module, str):
            out[module] = {c.get("id") for c in r.get("criteria", []) if isinstance(c, dict)}
    return out


def validate(exemplars, known, file_exists):
    errors = []
    seen = set()
    for i, ex in enumerate(exemplars):
        if not isinstance(ex, dict):
            errors.append(f"exemplar {i} is not an object")
            continue
        cid = ex.get("id")
        if not cid or cid in seen:
            errors.append(f"exemplar {i}: missing/duplicate id: {cid}")
        seen.add(cid)
        cat = ex.get("category")
        if cat not in known:
            errors.append(f"{cid}: unknown category '{cat}'")
        if ex.get("license") not in LICENSES:
            errors.append(f"{cid}: license must be one of {sorted(LICENSES)} (got '{ex.get('license')}')")
        rel = ex.get("file")
        if not isinstance(rel, str) or not file_exists(rel):
            errors.append(f"{cid}: file '{rel}' does not exist under exemplars/")
        crit = ex.get("criterion_id")
        if crit is not None and crit not in known.get(cat, set()):
            errors.append(f"{cid}: criterion_id '{crit}' not a criterion of '{cat}'")
        tier = ex.get("tier")
        if tier is not None and tier not in TIERS:
            errors.append(f"{cid}: bad tier '{tier}'")
    return (not errors), errors


def main():
    manifest = os.path.join(EXEMPLARS_DIR, "manifest.json")
    with open(manifest, encoding="utf-8") as f:
        data = json.load(f)
    items = data.get("exemplars", []) if isinstance(data, dict) else []
    ok, errors = validate(
        items, known_criteria(),
        lambda rel: os.path.isfile(os.path.join(EXEMPLARS_DIR, rel)),
    )
    if ok:
        print(f"VALID: {manifest} ({len(items)} exemplars)")
        sys.exit(0)
    print(f"INVALID: {manifest}")
    for e in errors:
        print("  -", e)
    sys.exit(1)


if __name__ == "__main__":
    main()
