"""Dependency-free tests for the sidecar-side agent loop. Run: python sidecar/test_agent_loop.py
Model + bridge are stubbed: no network, no Studio."""
import os
import sys
import tempfile
import time

import agent_loop


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


DESCRIBE = {
    "ok": True,
    "instructions": "BE EXCELLENT.",
    "tools": [{"name": "make_part", "description": "make a part", "input_schema": {"type": "object"}}],
    "baseUrl": "http://127.0.0.1:9",
    "proxyKey": "k",
    "model": "claude-test",
    "maxTokens": 100,
    "maxIterations": 10,
    "imagesKept": 2,
}

IMG = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AA=="}}


class FakeBridge:
    """Synchronous bridge: `describe` -> DESCRIBE, tools -> scripted results."""

    def __init__(self, tool_results):
        self.tool_results = list(tool_results)
        self.tool_calls = []

    def call(self, command, timeout):
        if command["kind"] == "describe":
            return dict(DESCRIBE)
        if command["kind"] == "tool":
            self.tool_calls.append(command)
            if not self.tool_results:
                return None  # simulate bridge timeout
            return self.tool_results.pop(0)
        return {"ok": False, "error": "unexpected"}


class FakeModel:
    """Returns scripted responses; records every request body."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.bodies = []

    def send(self, body):
        self.bodies.append(body)
        if not self.responses:
            return {"ok": False, "kind": "http", "status": 400, "message": "script exhausted"}
        return self.responses.pop(0)


def _runner(bridge, model, tmp):
    return agent_loop.LoopRunner(
        bridge, send_factory=lambda desc: model.send, loops_dir=tmp, sleep=lambda s: None
    )


def _wait_done(runner, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        st = runner.status()
        if st.get("state") in ("done", "error"):
            return st
        time.sleep(0.01)
    return runner.status()


def ok_response(content, stop="end_turn"):
    return {"ok": True, "data": {"content": content, "stop_reason": stop}}


def main():
    fails = 0
    tmp = tempfile.mkdtemp()

    # --- happy path: text -> tool_use -> tool_result -> final text ---
    bridge = FakeBridge([{"ok": True, "isError": False, "content": "part created", "banner": ""}])
    model = FakeModel(
        [
            ok_response(
                [
                    {"type": "text", "text": "making it"},
                    {"type": "tool_use", "id": "tu1", "name": "make_part", "input": {}},
                ]
            ),
            ok_response([{"type": "text", "text": "all done"}]),
        ]
    )
    r = _runner(bridge, model, tmp)
    r.start("build a part")
    st = _wait_done(r)
    fails += _check("completes with final text", st["state"] == "done" and st["result"] == "all done")
    fails += _check("dispatched the tool once", len(bridge.tool_calls) == 1 and bridge.tool_calls[0]["tool"] == "make_part")
    fails += _check("raw mode requested", bridge.tool_calls[0]["raw"] is True)
    first = model.bodies[0]
    fails += _check("preamble leads the send", "BE EXCELLENT." in first["messages"][0]["content"][0]["text"])
    fails += _check("preamble ack alternates", first["messages"][1]["role"] == "assistant")
    fails += _check("tools ride every send", first["tools"][0]["name"] == "make_part")
    second = model.bodies[1]
    tr = second["messages"][-1]["content"][0]
    fails += _check(
        "tool_result pairs the tool_use",
        tr["type"] == "tool_result" and tr["tool_use_id"] == "tu1" and tr["content"] == "part created",
    )
    fails += _check(
        "assistant turn echoed verbatim",
        second["messages"][-2]["content"][1]["type"] == "tool_use",
    )

    # --- structured (image) tool results + banner as text block ---
    bridge = FakeBridge(
        [
            {
                "ok": True,
                "isError": False,
                "content": [{"type": "text", "text": "1 capture:"}, dict(IMG)],
                "banner": "[WARN x]\n",
            }
        ]
    )
    model = FakeModel(
        [
            ok_response([{"type": "tool_use", "id": "tu1", "name": "capture", "input": {}}]),
            ok_response([{"type": "text", "text": "seen"}]),
        ]
    )
    r = _runner(bridge, model, tmp)
    r.start("look")
    st = _wait_done(r)
    blocks = model.bodies[1]["messages"][-1]["content"][0]["content"]
    fails += _check("image blocks forwarded", any(b.get("type") == "image" for b in blocks))
    fails += _check("banner prepended as text", blocks[0]["type"] == "text" and blocks[0]["text"].startswith("[WARN"))

    # --- keep-K image pruning across iterations (imagesKept=2) ---
    def img_result():
        return {"ok": True, "isError": False, "content": [dict(IMG)], "banner": ""}

    bridge = FakeBridge([img_result(), img_result(), img_result()])
    model = FakeModel(
        [
            ok_response([{"type": "tool_use", "id": f"t{i}", "name": "capture", "input": {}}])
            for i in (1, 2, 3)
        ]
        + [ok_response([{"type": "text", "text": "done"}])]
    )
    r = _runner(bridge, model, tmp)
    r.start("capture thrice")
    st = _wait_done(r)
    last_body = model.bodies[-1]

    def count_images(msgs):
        n = 0
        for m in msgs:
            for b in m.get("content", []):
                if isinstance(b, dict):
                    if b.get("type") == "image":
                        n += 1
                    inner = b.get("content")
                    if isinstance(inner, list):
                        n += sum(1 for x in inner if isinstance(x, dict) and x.get("type") == "image")
        return n

    fails += _check("keep-K pruning holds (2 kept)", count_images(last_body["messages"]) == 2)

    # --- error tool result flags is_error; empty-list content treated as empty ---
    bridge = FakeBridge([{"ok": False, "isError": True, "content": [], "banner": ""}])
    model = FakeModel(
        [
            ok_response([{"type": "tool_use", "id": "tu1", "name": "make_part", "input": {}}]),
            ok_response([{"type": "text", "text": "recovered"}]),
        ]
    )
    r = _runner(bridge, model, tmp)
    r.start("x")
    st = _wait_done(r)
    tr = model.bodies[1]["messages"][-1]["content"][0]
    fails += _check("is_error carried", tr.get("is_error") is True and st["state"] == "done")
    fails += _check("empty luau [] content survives", isinstance(tr["content"], str) and tr["content"] != "")

    # --- bridge timeout becomes an is_error result, loop continues ---
    bridge = FakeBridge([])  # no results -> timeout
    model = FakeModel(
        [
            ok_response([{"type": "tool_use", "id": "tu1", "name": "make_part", "input": {}}]),
            ok_response([{"type": "text", "text": "gave up"}]),
        ]
    )
    r = agent_loop.LoopRunner(bridge, send_factory=lambda d: model.send, loops_dir=tmp, sleep=lambda s: None)
    agent_loop.TOOL_TIMEOUT, saved = 0.01, agent_loop.TOOL_TIMEOUT
    r.start("x")
    st = _wait_done(r)
    agent_loop.TOOL_TIMEOUT = saved
    tr = model.bodies[1]["messages"][-1]["content"][0]
    fails += _check("bridge timeout -> is_error tool_result", tr.get("is_error") is True and "timeout" in tr["content"])

    # --- transient retry then success; usage-window never retries ---
    calls = {"n": 0}

    def flaky(body):
        calls["n"] += 1
        if calls["n"] == 1:
            return {"ok": False, "kind": "http", "status": 529, "message": "overloaded"}
        return ok_response([{"type": "text", "text": "fine"}])

    r = agent_loop.LoopRunner(
        FakeBridge([]), send_factory=lambda d: flaky, loops_dir=tmp, sleep=lambda s: None
    )
    r.start("x")
    st = _wait_done(r)
    fails += _check("transient retried to success", st["state"] == "done" and calls["n"] == 2)
    fails += _check(
        "usage-window not transient",
        agent_loop.is_transient({"kind": "http", "status": 400, "message": "out of extra usage this week"}) is False,
    )
    fails += _check(
        "cold-proxy race transient",
        agent_loop.is_transient({"kind": "http", "status": 400, "message": "unknown provider for model x"}) is True,
    )

    # --- single-flight: second start while running raises ---
    slow_bridge = FakeBridge([])

    class SlowModel:
        def send(self, body):
            time.sleep(0.3)
            return ok_response([{"type": "text", "text": "slow done"}])

    r = agent_loop.LoopRunner(slow_bridge, send_factory=lambda d: SlowModel().send, loops_dir=tmp)
    r.start("first")
    try:
        r.start("second")
        fails += _check("second start rejected", False)
    except agent_loop.LoopError:
        fails += _check("second start rejected", True)
    _wait_done(r)

    # --- Luau [] -> {} schema normalization ---
    tools = [
        {"name": "noargs", "input_schema": []},
        {"name": "empty_props", "input_schema": {"type": "object", "properties": []}},
        {"name": "nested", "input_schema": {"type": "object", "properties": {"x": {"type": "object", "properties": []}}, "required": []}},
    ]
    fixed = agent_loop.fix_luau_empty_objects(tools)
    fails += _check("[] input_schema becomes object", fixed[0]["input_schema"] == {"type": "object", "properties": {}})
    fails += _check("[] properties becomes {}", fixed[1]["input_schema"]["properties"] == {})
    fails += _check("nested [] properties fixed", fixed[2]["input_schema"]["properties"]["x"]["properties"] == {})
    fails += _check("required [] untouched", fixed[2]["input_schema"]["required"] == [])

    # --- describe timeout fails cleanly ---
    class DeadBridge:
        def call(self, command, timeout):
            return None

    r = agent_loop.LoopRunner(DeadBridge(), send_factory=lambda d: None, loops_dir=tmp, sleep=lambda s: None)
    agent_loop.DESCRIBE_TIMEOUT, saved = 0.01, agent_loop.DESCRIBE_TIMEOUT
    r.start("x")
    st = _wait_done(r)
    agent_loop.DESCRIBE_TIMEOUT = saved
    fails += _check("dead bridge -> clean error", st["state"] == "error" and "describe" in st["error"])

    # --- start() validates BEFORE committing state (no wedge) ---
    r = _runner(FakeBridge([]), FakeModel([]), tmp)
    try:
        r.start("x", max_iterations="ten")
        fails += _check("bad maxIterations rejected in start()", False)
    except agent_loop.LoopError:
        fails += _check("bad maxIterations rejected in start()", True)
    fails += _check("state not wedged after bad start", r.status().get("state") != "running")

    # --- an internal throw sets state=error instead of wedging "running" ---
    def bomb_factory(desc):
        raise RuntimeError("kaboom")

    r = agent_loop.LoopRunner(FakeBridge([]), send_factory=bomb_factory, loops_dir=tmp, sleep=lambda s: None)
    r.start("x")
    st = _wait_done(r)
    fails += _check("internal throw -> state=error", st["state"] == "error" and "kaboom" in st["error"])
    r2 = r.start("again")  # runner must accept a new run after the crash
    fails += _check("runner reusable after crash", isinstance(r2, int))
    _wait_done(r)

    # --- pause_turn resumes instead of terminating ---
    model = FakeModel(
        [
            {"ok": True, "data": {"content": [{"type": "text", "text": "searching…"}], "stop_reason": "pause_turn"}},
            ok_response([{"type": "text", "text": "found it"}]),
        ]
    )
    r = _runner(FakeBridge([]), model, tmp)
    r.start("research")
    st = _wait_done(r)
    fails += _check("pause_turn resumed to completion", st["state"] == "done" and st["result"] == "found it")
    fails += _check("paused turn echoed back", model.bodies[1]["messages"][-1]["content"][0]["text"] == "searching…")

    # --- max_tokens gets a continuation nudge, not a silent truncated done ---
    model = FakeModel(
        [
            {"ok": True, "data": {"content": [{"type": "text", "text": "part one"}], "stop_reason": "max_tokens"}},
            ok_response([{"type": "text", "text": "part two"}]),
        ]
    )
    r = _runner(FakeBridge([]), model, tmp)
    r.start("write a lot")
    st = _wait_done(r)
    fails += _check("max_tokens continued", st["state"] == "done" and st["result"] == "part two")
    nudge = model.bodies[1]["messages"][-1]
    fails += _check(
        "continuation nudge appended as user turn",
        nudge["role"] == "user" and "token cap" in nudge["content"][0]["text"],
    )

    # --- empty content array = clean terminal stop, not an error ---
    model = FakeModel([{"ok": True, "data": {"content": [], "stop_reason": "max_tokens"}}])
    r = _runner(FakeBridge([]), model, tmp)
    r.start("x")
    st = _wait_done(r)
    fails += _check("empty content -> clean done", st["state"] == "done")

    # --- context overflow triggers a one-shot trim and retry ---
    calls2 = {"n": 0}

    def overflow_then_ok(body):
        calls2["n"] += 1
        if calls2["n"] == 2:  # first send of iteration 2 (history now has a big tool_result)
            return {"ok": False, "kind": "http", "status": 400, "message": "prompt is too long: 210000 tokens"}
        if calls2["n"] == 1:
            return ok_response([{"type": "tool_use", "id": "t1", "name": "get_tree", "input": {}}])
        return ok_response([{"type": "text", "text": "recovered after trim"}])

    big = {"ok": True, "isError": False, "content": "X" * 5000, "banner": ""}
    r = agent_loop.LoopRunner(FakeBridge([big]), send_factory=lambda d: overflow_then_ok, loops_dir=tmp, sleep=lambda s: None)
    r.start("big job")
    st = _wait_done(r)
    fails += _check("overflow trimmed and recovered", st["state"] == "done" and st["result"] == "recovered after trim")

    # --- events counter is monotonic in status ---
    fails += _check("events counter present", int(st.get("events") or 0) >= 2)

    # --- BridgeCaller timeout classification + result consumption (real Store) ---
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from bridge import Store

    store = Store()
    bc = agent_loop.BridgeCaller(store, poll_interval=0.001)
    out = bc.call({"kind": "tool", "tool": "x"}, 0.05)  # nobody serves it
    fails += _check("undispatched timeout detected", out["_timeout"] is True and out["dispatched"] is False)
    fails += _check("reclaimed command cleared", store.take_pending() is None)
    cid = store.submit({"kind": "tool"})
    store.put_result(cid, {"ok": True})
    fails += _check("pop_result consumes", store.pop_result(cid) == {"ok": True} and store.pop_result(cid) is None)
    for n in range(60):
        store.put_result(1000 + n, {"n": n})
    fails += _check("results map bounded", store.get_result(1000) is None and store.get_result(1059) is not None)

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
