"""Persist a train-recipe factory run's output into a build guide + a report.

Usage:  python scripts/save_recipe_guide.py <category> <run-output-file> [<date>]
- Reads the workflow result JSON ({category, guide, coverage, review, provenance}).
- Writes docs/superpowers/guides/<category>.guide.json (pretty) and <category>-guide-report.md.
- Prints a one-line coverage summary so the orchestrator can gate on full coverage.
"""
import datetime
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUIDES = os.path.join(ROOT, "docs", "superpowers", "guides")


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: save_recipe_guide.py <category> <run-output-file> [<date>]")
    cat = sys.argv[1].strip().lower()
    out_path = sys.argv[2]
    date = sys.argv[3] if len(sys.argv) > 3 else datetime.date.today().isoformat()

    with open(out_path, encoding="utf-8") as f:
        data = json.load(f)
    # The task-output file wraps the workflow return under "result"; older shapes return it directly.
    res = data.get("result", data) if isinstance(data, dict) else data
    if isinstance(res, str):
        res = json.loads(res)
    guide = res.get("guide") if isinstance(res, dict) else None
    if not isinstance(guide, dict):
        sys.exit("run output has no 'guide' object (keys: %s)" % (list(res.keys()) if isinstance(res, dict) else type(res).__name__))
    guide.setdefault("date", date)

    guide_path = os.path.join(GUIDES, cat + ".guide.json")
    with open(guide_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(guide, f, ensure_ascii=False, indent=2)
        f.write("\n")

    cov = res.get("coverage", {}) or {}
    prov_cov = (guide.get("provenance", {}) or {}).get("coverage", {}) or {}
    total = cov.get("total", prov_cov.get("criteria_total", 0))
    addressed = cov.get("addressed", prov_cov.get("criteria_addressed", 0))
    uncovered = cov.get("uncovered", prov_cov.get("uncovered", []))
    review = res.get("review", {}) or {}
    prov = res.get("provenance", {}) or {}
    n_steps = sum(len(t.get("steps", [])) for t in guide.get("tiers", []))
    n_tiers = len(guide.get("tiers", []))

    lines = [
        "# Build guide report: %s (v%s)" % (cat, guide.get("version", "?")),
        "",
        "Generated %s by the `train-recipe` factory; targets the %s rubric (v%s)."
        % (date, cat, guide.get("rubric_version", "?")),
        "",
        "## Coverage",
        "- Rubric criteria addressed: **%s / %s**" % (addressed, total),
        "- Steps: %s across %s tiers" % (n_steps, n_tiers),
        "- Uncovered criteria: %s"
        % ("none" if not uncovered else ", ".join("`%s`" % u for u in uncovered)),
        "",
        "## Completeness review",
        "- Killer systems covered: %s"
        % ", ".join(review.get("killer_systems_covered", []) or ["(none reported)"]),
        "- Killer systems missing: %s"
        % ", ".join(review.get("killer_systems_missing", []) or ["none"]),
        "- Build order sound: %s" % review.get("build_order_sound", "?"),
        "",
        "### Assessment",
        review.get("assessment", "(none)"),
        "",
        "## Provenance",
        "- Sweep angles: %s" % ", ".join(prov.get("angles", []) or []),
        "- Techniques gathered: %s" % prov.get("techniqueCount", "?"),
        "- Coverage-fill rounds: %s" % prov.get("fillRounds", "?"),
        "",
    ]
    report_path = os.path.join(GUIDES, cat + "-guide-report.md")
    with open(report_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))

    status = "FULL" if uncovered == [] or uncovered == () else "PARTIAL(%d uncovered)" % len(uncovered)
    print(
        "%s: wrote %s + report | coverage %s/%s [%s] | steps=%s tiers=%s"
        % (cat, os.path.basename(guide_path), addressed, total, status, n_steps, n_tiers)
    )


if __name__ == "__main__":
    main()
