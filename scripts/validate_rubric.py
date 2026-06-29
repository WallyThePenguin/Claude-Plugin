"""Stdlib structural validator for a category rubric (matches rubric.schema.json)."""
import json
import sys

TIERS = {"baseline", "good", "exceptional"}
TOP_REQUIRED = ["module", "version", "criteria"]
CRIT_REQUIRED = ["id", "order_index", "tier", "statement",
                 "above_generic_rationale", "grading", "evidence_required", "concrete_fix"]
GRADING_REQUIRED = ["pass", "partial", "fail"]


def validate(rubric):
    errors = []
    if not isinstance(rubric, dict):
        return False, ["rubric is not an object"]
    for k in TOP_REQUIRED:
        if k not in rubric:
            errors.append(f"missing top-level field: {k}")
    crits = rubric.get("criteria")
    if not isinstance(crits, list) or not crits:
        errors.append("criteria must be a non-empty array")
        return (not errors), errors
    seen_ids = set()
    for i, c in enumerate(crits):
        if not isinstance(c, dict):
            errors.append(f"criterion {i} is not an object")
            continue
        for k in CRIT_REQUIRED:
            if k not in c:
                errors.append(f"criterion {i} missing: {k}")
        if c.get("tier") not in TIERS:
            errors.append(f"criterion {i} bad tier: {c.get('tier')}")
        cid = c.get("id")
        if cid in seen_ids:
            errors.append(f"duplicate criterion id: {cid}")
        seen_ids.add(cid)
        g = c.get("grading")
        if not isinstance(g, dict) or any(k not in g for k in GRADING_REQUIRED):
            errors.append(f"criterion {i} grading must have pass/partial/fail")
    return (not errors), errors


def main():
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        ok, errors = validate(json.load(f))
    if ok:
        print(f"VALID: {path}")
        sys.exit(0)
    print(f"INVALID: {path}")
    for e in errors:
        print("  -", e)
    sys.exit(1)


if __name__ == "__main__":
    main()
