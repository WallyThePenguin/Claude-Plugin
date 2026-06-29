#!/usr/bin/env python3
"""auto-improve.py - the disciplined self-directed improvement loop.

Reads its charter (docs/superpowers/auto-improve-charter.md) and runs:

    DIRECTOR (CLIProxyAPI - the subscription Claude via the tunnel) prioritizes the next stone from the
    backlog and adversarially critiques the previous turn's evidence
      -> WORKER (`claude -p`, Claude Code with HANDS on the repo + the Studio bridge) executes ONE stone,
         gathers REAL evidence (selene/rojo/Spec/a capture it looks at), commits LOCALLY if the oracle
         passes, and reports a status
      -> log the turn, check stop conditions, repeat.

Why this shape (learned the hard way 2026-06-27/28): the worker is the only node that can SEE the
environment, so it is the witness; the director is a planner/critic, NOT a boss (its instructions are
hypotheses the worker verifies). The HUMAN stays in the loop at the ground-truth / taste / irreversible
boundary - that class of error (e.g. "this is Team Create, not a playtest") is invisible to every Claude
and is exactly the class that produces a confident fake-done. So this loop is "infinite" only over the
CHECKABLE backlog; it HALTS for the human at those boundaries instead of faking completion.

Guardrails (non-negotiable): commits stay LOCAL (the worker is told never to push; this script never
pushes), and the loop stops on NEEDS_HUMAN / HALT / DONE_ALL / max-iters.

Usage:
    python scripts/auto-improve.py [--max-iters N] [--director proxy|claude] [--dry-run]
Env:
    LOOP_DIRECTOR_URL   default http://127.0.0.1:8318/v1/messages   (the CLIProxyAPI tunnel)
    LOOP_DIRECTOR_KEY   Bearer key for the proxy (hecate CPAPI_INBOUND_KEY). If unset and --director
                        proxy, falls back to the `claude` CLI as director.
    LOOP_MODEL          default claude-opus-4-8
    LOOP_CLAUDE_CMD     default "claude"   (the Claude Code CLI used for the worker / claude-director)

Worker auth: the `claude -p` worker uses YOUR logged-in Claude Code credentials (run it from your normal
authenticated shell - a bare `claude -p` with no inherited auth returns HTTP 401). To route the worker
AND the director through the CLIProxyAPI tunnel exactly like the plugin does (your subscription), export
before running:  ANTHROPIC_BASE_URL=http://127.0.0.1:8318  ANTHROPIC_API_KEY=<your proxy key>  - the
harness inherits your shell env. The plugin's tunnel (proxy/tunnel.ps1) and the Studio dev bridge should
be up so the worker can drive Studio for visual stones.

Verified: syntax, --dry-run prompt assembly, and that `claude -p --output-format json` returns a parseable
{result:...}. NOT verified end-to-end here (the sandbox `claude -p` 401'd with no inherited auth, and the
proxy director needs your LOOP_DIRECTOR_KEY) - run it from your authed shell to take it live.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHARTER = os.path.join(ROOT, "docs", "superpowers", "auto-improve-charter.md")
LOG = os.path.join(ROOT, "docs", "superpowers", "auto-improve-log.md")
MODEL = os.environ.get("LOOP_MODEL", "claude-opus-4-8")
CLAUDE = os.environ.get("LOOP_CLAUDE_CMD", "claude")
DIRECTOR_URL = os.environ.get("LOOP_DIRECTOR_URL", "http://127.0.0.1:8318/v1/messages")
DIRECTOR_KEY = os.environ.get("LOOP_DIRECTOR_KEY", "")

STATUS_RE = re.compile(r"<<STATUS:\s*(DONE_STONE|BLOCKED|NEEDS_HUMAN|DONE_ALL)\s*>>")
HALT_RE = re.compile(r"<<HALT:\s*(.+?)>>", re.S)


def read_text(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return default


def log_tail(n_chars=4000):
    return read_text(LOG)[-n_chars:]


def append_log(entry):
    with open(LOG, "a", encoding="utf-8", newline="\n") as f:
        f.write(entry.rstrip() + "\n\n")


# ---- DIRECTOR: the CLIProxyAPI (subscription Claude) plans + critiques. NOTE the proxy STRIPS the
# `system` field, so ALL instructions ride in a leading USER message. Transient 502 "unknown provider"
# on a cold proxy is retried. Falls back to the `claude` CLI if no key / the proxy is unreachable.
def director_prompt(charter, tail, last_evidence):
    return (
        "You are the DIRECTOR of a disciplined self-improvement loop for a Roblox Studio plugin. You do "
        "NOT have hands on the repo; the WORKER (Claude Code) does. Your job: (1) adversarially CRITIQUE "
        "the previous turn's evidence below - try to find where it is wrong, incomplete, or a fake-done; "
        "(2) pick the single highest-value UNBLOCKED stone from the charter backlog as the next directive; "
        "(3) decide if the loop must HALT for the human (a taste call, an irreversible action, or a "
        "ground-truth question only a human looking at Studio can answer). Treat your own picks as "
        "HYPOTHESES the worker will verify - never assert a fact about the repo you cannot see.\n\n"
        "Respond with EXACTLY one minified JSON object and nothing else:\n"
        '{"critique": "<=2 sentences on the prev evidence (or \'first turn\')", '
        '"directive": "the one concrete stone for the worker to do next", '
        '"halt": false, "halt_reason": ""}\n\n'
        "=== CHARTER (source of truth) ===\n" + charter + "\n\n"
        "=== RECENT PROGRESS LOG ===\n" + (tail or "(empty - first turn)") + "\n\n"
        "=== PREVIOUS TURN EVIDENCE ===\n" + (last_evidence or "(none - first turn)")
    )


def ask_director_proxy(prompt):
    if not DIRECTOR_KEY:
        return None
    body = json.dumps({
        "model": MODEL, "max_tokens": 1024,
        "messages": [{"role": "user", "content": prompt}],
    }).encode("utf-8")
    headers = {
        "content-type": "application/json", "anthropic-version": "2023-06-01",
        "authorization": "Bearer " + DIRECTOR_KEY,
    }
    for attempt in range(6):  # absorb the cold-proxy transient 502 "unknown provider for model"
        try:
            req = urllib.request.Request(DIRECTOR_URL, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=120) as r:
                data = json.loads(r.read().decode("utf-8"))
            parts = [b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"]
            return "".join(parts).strip()
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", "replace")
            if e.code in (502, 503) or "unknown provider" in msg:
                time.sleep(12)
                continue
            print("[director] proxy HTTP %s: %s" % (e.code, msg[:200]), file=sys.stderr)
            return None
        except Exception as e:  # noqa: BLE001 - network is best-effort; fall back to claude
            print("[director] proxy error: %s" % e, file=sys.stderr)
            return None
    return None


def ask_director_claude(prompt):
    out = run_claude(prompt, with_tools=False)
    return out


def parse_director(text):
    if not text:
        return None
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
        return {
            "critique": str(obj.get("critique", "")),
            "directive": str(obj.get("directive", "")),
            "halt": bool(obj.get("halt", False)),
            "halt_reason": str(obj.get("halt_reason", "")),
        }
    except json.JSONDecodeError:
        return None


def get_directive(charter, tail, last_evidence, backend):
    prompt = director_prompt(charter, tail, last_evidence)
    text = ask_director_proxy(prompt) if backend == "proxy" else None
    if text is None:
        text = ask_director_claude(prompt)  # fallback / --director claude
    d = parse_director(text)
    if d is None:
        # last resort: let the worker self-direct from the charter backlog
        return {"critique": "(director unavailable; worker self-directs)",
                "directive": "Read the charter backlog and do the single highest-value unblocked stone.",
                "halt": False, "halt_reason": ""}
    return d


# ---- WORKER: `claude -p` Claude Code with hands. Executes ONE stone, gathers evidence, commits local. ----
def worker_prompt(charter, directive, critique):
    return (
        "You are the WORKER in a disciplined self-improvement loop, running headless via `claude -p` in "
        "the Studio-plugin repo. Follow the CHARTER below EXACTLY. The DIRECTOR (who cannot see the repo) "
        "proposed the directive - treat it as a HYPOTHESIS to verify against the real environment, not an "
        "order; if it's wrong, do what's actually right and say so.\n\n"
        "DO, in one turn:\n"
        "1. Execute the SINGLE stone named by the directive (or, if the directive is wrong/blocked, the "
        "best unblocked charter stone). One stone only.\n"
        "2. Gather a REAL oracle: `selene src` 0/0, `rojo build default.project.json -o StudioAgent.rbxm` "
        "green, the relevant Spec via the bridge, AND for anything visual a capture you actually look at "
        "(the structural census is NOT sufficient - it has lied before). Before any build/capture, check "
        "the run context (a [WARN run-context] banner on bridge results = a real playtest; and `capture` "
        "fetches the LAST buffered shot, so trigger a fresh `tool capture` first).\n"
        "3. Adversarially try to REFUTE your own 'done' before believing it.\n"
        "4. If it passes the oracle: commit LOCALLY (never push) with a clear message. If it doesn't: "
        "leave it uncommitted and report BLOCKED honestly.\n"
        "5. STOP and do NOT proceed if you hit a TASTE call ('is this actually good/beautiful'), an "
        "IRREVERSIBLE action (push/publish/spend/secret), or a GROUND-TRUTH question only a human looking "
        "at Studio can answer - emit `<<HALT: the specific question for the human>>`.\n\n"
        "END your reply with these markers on their own lines:\n"
        "<<STATUS: DONE_STONE|BLOCKED|NEEDS_HUMAN|DONE_ALL>>\n"
        "<<EVIDENCE: one paragraph - the stone, the raw oracle results (selene/rojo/spec/capture verdict), "
        "the commit sha or why none, and anything the next director turn must know>>\n\n"
        "=== DIRECTOR CRITIQUE OF LAST TURN ===\n" + (critique or "(first turn)") + "\n\n"
        "=== DIRECTIVE (a hypothesis) ===\n" + directive + "\n\n"
        "=== CHARTER ===\n" + charter
    )


def run_claude(prompt, with_tools):
    cmd = [CLAUDE, "-p", "--output-format", "json"]
    if with_tools:
        cmd.append("--dangerously-skip-permissions")  # autonomous worker; guardrails are in the prompt
    cmd.append(prompt)
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=1800)
    except FileNotFoundError:
        print("[worker] `%s` not found - set LOOP_CLAUDE_CMD." % CLAUDE, file=sys.stderr)
        return ""
    except subprocess.TimeoutExpired:
        return "<<STATUS: BLOCKED>>\n<<EVIDENCE: worker turn timed out (30m)>>"
    raw = proc.stdout.strip()
    try:  # claude -p --output-format json -> {type:result, result:"<text>", ...}
        obj = json.loads(raw)
        return obj.get("result", raw) if isinstance(obj, dict) else raw
    except json.JSONDecodeError:
        return raw or proc.stderr.strip()


def run_worker(charter, directive, critique):
    out = run_claude(worker_prompt(charter, directive, critique), with_tools=True)
    sm = STATUS_RE.search(out or "")
    hm = HALT_RE.search(out or "")
    status = "NEEDS_HUMAN" if hm else (sm.group(1) if sm else "BLOCKED")
    ev = ""
    em = re.search(r"<<EVIDENCE:\s*(.+?)>>", out or "", re.S)
    if em:
        ev = em.group(1).strip()
    elif hm:
        ev = "HALT: " + hm.group(1).strip()
    return {"status": status, "evidence": ev or (out or "")[-1500:], "raw": out or ""}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-iters", type=int, default=8)
    ap.add_argument("--director", choices=["proxy", "claude"], default="proxy")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the assembled director+worker prompts for iter 1 and exit (no claude calls)")
    ap.add_argument("--ask", action="store_true",
                    help="ME-AS-WORKER mode: print the director's next {critique,directive,halt} (JSON) "
                         "given the charter + log (+ --evidence of my last turn). The interactive agent IS "
                         "the worker; this just consults the director. Use with --director proxy.")
    ap.add_argument("--evidence", default="",
                    help="my last turn's evidence; appended to the log and sent to the director")
    args = ap.parse_args()

    charter = read_text(CHARTER)
    if not charter:
        sys.exit("charter not found at %s - run from the repo root." % CHARTER)

    if args.ask:
        if args.evidence:
            append_log("## worker evidence\n" + args.evidence)
        d = get_directive(charter, log_tail(), args.evidence or None, args.director)
        print(json.dumps(d))
        return

    if args.dry_run:
        d = director_prompt(charter, log_tail(), "(none)")
        print("===== DIRECTOR PROMPT (iter 1) =====\n" + d[:1500] + "\n...[truncated]\n")
        w = worker_prompt(charter, "<the director's directive>", "<the director's critique>")
        print("===== WORKER PROMPT (iter 1) =====\n" + w[:1800] + "\n...[truncated]\n")
        print("director backend=%s  model=%s  proxy_key=%s  claude=%s"
              % (args.director, MODEL, "set" if DIRECTOR_KEY else "UNSET (will fall back to claude)", CLAUDE))
        return

    last_evidence = None
    for i in range(1, args.max_iters + 1):
        print("\n=== iteration %d/%d ===" % (i, args.max_iters))
        d = get_directive(charter, log_tail(), last_evidence, args.director)
        print("[director] critique: %s" % d["critique"][:200])
        if d["halt"]:
            append_log("## iter %d - DIRECTOR HALT\n%s" % (i, d["halt_reason"]))
            print("[HALT - director] %s" % d["halt_reason"])
            break
        print("[director] directive: %s" % d["directive"][:200])
        w = run_worker(charter, d["directive"], d["critique"])
        append_log("## iter %d\n- directive: %s\n- status: %s\n- evidence: %s"
                   % (i, d["directive"], w["status"], w["evidence"]))
        print("[worker] status=%s" % w["status"])
        last_evidence = "directive: %s\nstatus: %s\nevidence: %s" % (d["directive"], w["status"], w["evidence"])
        if w["status"] in ("NEEDS_HUMAN", "DONE_ALL"):
            print("[STOP] %s - handing back to the human." % w["status"])
            break
    else:
        print("[STOP] reached --max-iters %d." % args.max_iters)
    print("log: %s" % LOG)


if __name__ == "__main__":
    main()
