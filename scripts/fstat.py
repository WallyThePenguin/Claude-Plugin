"""One-line forever-loop status summary for the monitor (reads the TOP-LEVEL fields correctly)."""
import json
import urllib.request

try:
    s = json.load(urllib.request.urlopen("http://127.0.0.1:8389/forever/status", timeout=5))
except Exception as exc:  # noqa: BLE001
    print(f"status-unavailable: {exc}")
    raise SystemExit(0)

state = s.get("state")
cyc = s.get("cycle", 0)
fam = s.get("family", "?")
rung = s.get("rung", "?")
prop = s.get("proposalsAdded", 0)
stage = s.get("factoryStage") or s.get("stage") or ""
if state == "running":
    print(f"RUN cycle {cyc} | {fam} -> {rung} | {stage} | proposals {prop}")
else:
    print(f"END {state} ({s.get('stopped', '')}) after {cyc} cycles, {prop} proposals")
