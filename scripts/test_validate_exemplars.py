"""Dependency-free tests for validate_exemplars.validate(). Run: python scripts/test_validate_exemplars.py"""
import sys

import validate_exemplars as v


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    known = {"environment": {"env-foliage"}, "gui": {"gui-anchor"}}
    def exists(rel):
        return rel in ("environment/a.png", "gui/b.png")

    good = [{"id": "e1", "category": "environment", "file": "environment/a.png",
             "license": "own", "criterion_id": "env-foliage", "tier": "exceptional"}]
    ok, _ = v.validate(good, known, exists)
    fails += _check("a clean entry validates", ok)

    ok, _ = v.validate([{"id": "e2", "category": "environment", "file": "environment/a.png",
                         "license": "copyrighted"}], known, exists)
    fails += _check("copyrighted license rejected", not ok)

    ok, _ = v.validate([{"id": "e3", "category": "nope", "file": "environment/a.png",
                         "license": "own"}], known, exists)
    fails += _check("unknown category rejected", not ok)

    ok, _ = v.validate([{"id": "e4", "category": "gui", "file": "gui/missing.png",
                         "license": "cc0"}], known, exists)
    fails += _check("missing file rejected", not ok)

    ok, _ = v.validate([{"id": "d", "category": "gui", "file": "gui/b.png", "license": "own"},
                        {"id": "d", "category": "gui", "file": "gui/b.png", "license": "own"}], known, exists)
    fails += _check("duplicate id rejected", not ok)

    ok, _ = v.validate([{"id": "e5", "category": "gui", "file": "gui/b.png", "license": "own",
                         "criterion_id": "no-such"}], known, exists)
    fails += _check("criterion_id not in category rejected", not ok)

    ok, _ = v.validate([{"category": "gui", "file": "gui/b.png", "license": "own"}], known, exists)
    fails += _check("missing id rejected", not ok)

    ok, _ = v.validate([{"id": "e6", "category": "gui", "file": "gui/b.png",
                         "license": "own", "tier": "amazing"}], known, exists)
    fails += _check("bad tier rejected", not ok)

    ok, _ = v.validate(None, known, exists)
    fails += _check("non-list exemplars rejected", not ok)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
