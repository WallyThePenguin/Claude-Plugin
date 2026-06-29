#!/usr/bin/env python3
"""grade_via_proxy.py - grade specific rubric criteria against build evidence using the CLIProxyAPI.

A fallback grader for when the plugin's own `evaluate` can't reach its model (e.g. the 8318 tunnel's
remote chain is down): the worker grades via the working local proxy (8319). NOT a replacement for
evaluate's full visual grading - a focused, honest per-criterion verdict from real structural evidence
(+ a human-looked-at capture noted in the evidence).

Usage:
    python scripts/grade_via_proxy.py <category> <id1,id2,...>   # evidence + design read from stdin (JSON:
                                                                 # {"design": "...", "evidence": "..."})
Env: LOOP_DIRECTOR_URL (default 8319), LOOP_DIRECTOR_KEY, LOOP_MODEL.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = os.environ.get("LOOP_DIRECTOR_URL", "http://127.0.0.1:8319/v1/messages")
KEY = os.environ.get("LOOP_DIRECTOR_KEY", "")
MODEL = os.environ.get("LOOP_MODEL", "claude-opus-4-8")


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: grade_via_proxy.py <category> <id1,id2,...>  (design+evidence on stdin)")
    cat, ids = sys.argv[1], [s.strip() for s in sys.argv[2].split(",") if s.strip()]
    stdin = json.loads(sys.stdin.read() or "{}")
    design, evidence = stdin.get("design", ""), stdin.get("evidence", "")
    with open(os.path.join(ROOT, "docs", "superpowers", "rubrics", cat + ".rubric.json"), encoding="utf-8") as f:
        rub = json.load(f)
    crit = [c for c in rub.get("criteria", []) if c.get("id") in ids]
    if len(crit) != len(ids):
        sys.exit("not all ids found: %s" % ids)
    brief = [{"id": c["id"], "statement": c.get("statement", ""), "grading": c.get("grading", {})} for c in crit]

    prompt = (
        "You are a STRICT rubric grader. Grade ONLY these %s criteria against the build evidence below. "
        "Score each pass/partial/fail STRICTLY by its grading.pass/partial/fail definition and the cited "
        "evidence - never on vibe, never inflate. If the evidence genuinely meets pass, say pass; if not, "
        "say partial/fail and why.\n\nRespond with EXACTLY one minified JSON array, one object per criterion: "
        '[{"id":"...","score":"pass|partial|fail","evidence":"<=2 sentences citing the build evidence"}]\n\n'
        "=== CRITERIA ===\n%s\n\n=== DESIGN CLAIM ===\n%s\n\n=== BUILD EVIDENCE (structural dump + a "
        "human-looked-at capture) ===\n%s"
    ) % (cat, json.dumps(brief, indent=1), design, evidence)

    body = json.dumps({"model": MODEL, "max_tokens": 800,
                       "messages": [{"role": "user", "content": prompt}]}).encode("utf-8")
    headers = {"content-type": "application/json", "anthropic-version": "2023-06-01",
               "authorization": "Bearer " + KEY}
    for _ in range(6):
        try:
            req = urllib.request.Request(URL, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=120) as r:
                data = json.loads(r.read().decode("utf-8"))
            text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
            print(text.strip())
            return
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", "replace")
            if e.code in (502, 503) or "unknown provider" in msg:
                time.sleep(12)
                continue
            sys.exit("HTTP %s: %s" % (e.code, msg[:200]))
        except Exception as e:  # noqa: BLE001
            sys.exit("grade error: %s" % e)
    sys.exit("grader unreachable")


if __name__ == "__main__":
    main()
