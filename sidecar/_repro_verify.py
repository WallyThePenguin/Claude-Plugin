"""REPRO: the verify stage emits no verdict/evidence.

Root cause: LoopRunner._run_inner reports state='done' with result='' when the model's
final turn carries NO text (empty content array / cap hit before any text). factory.py then
gets text='', _last_json -> None, and falls back to UNVERIFIED reasons=['verify produced no
verdict'] with NO transcript tail (because tail of '' is falsy) and evidence=None.
"""
import tempfile, time
import agent_loop, factory


class FakeBridge:
    def call(self, command, timeout):
        if command["kind"] == "describe":
            return {
                "ok": True, "instructions": "x",
                "tools": [{"name": "make_part", "description": "d", "input_schema": {"type": "object"}}],
                "baseUrl": "http://127.0.0.1:9", "proxyKey": "k", "model": "claude-test",
                "maxTokens": 100, "maxIterations": 10, "imagesKept": 2,
            }
        return {"ok": True, "isError": False, "content": "ok", "banner": ""}


class FakeModel:
    def __init__(self, responses):
        self.responses = list(responses)
    def send(self, body):
        return self.responses.pop(0) if self.responses else {"ok": False, "kind": "http", "status": 400, "message": "exhausted"}


def _wait(runner, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        st = runner.status()
        if st.get("state") in ("done", "error"):
            return st
        time.sleep(0.01)
    return runner.status()


tmp = tempfile.mkdtemp()

# The verify loop ends with an empty final turn (content=[] — the model hit the cap before
# emitting the FACTORY_VERIFY_JSON line).
model = FakeModel([{"ok": True, "data": {"content": [], "stop_reason": "max_tokens"}}])
r = agent_loop.LoopRunner(FakeBridge(), send_factory=lambda d: model.send, loops_dir=tmp, sleep=lambda s: None)
r.start("verify the weapon")
st = _wait(r)
loop_result = st.get("result")
print(f"loop state    : {st.get('state')}")
print(f"loop result   : {loop_result!r}")

# Downstream: factory.py's verify fallback given this empty text.
ok, text, err = True, str(loop_result or ""), None
verify = factory._last_json(text, factory.VERIFY_JSON_RE) if ok else None
if not verify or verify.get("status") not in ("PASSED", "FAILED", "UNVERIFIED"):
    reasons = [err or "verify produced no verdict"]
    tail = (text or "").strip()[-600:]
    if tail:
        reasons.append("no FACTORY_VERIFY_JSON; transcript tail: " + tail)
    verify = {"status": "UNVERIFIED", "reasons": reasons}
print(f"verify status : {verify['status']}")
print(f"verifyEvidence: {verify.get('evidence')!r}")
print(f"verifyReasons : {verify['reasons']!r}")

symptom = (
    st.get("state") == "done"
    and loop_result == ""
    and verify.get("evidence") is None
    and verify["reasons"] == ["verify produced no verdict"]
)
print("REPRO " + ("CONFIRMED" if symptom else "not reproduced"))
