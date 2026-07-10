"""Dependency-free tests for the SDK-backed loop. Run: python sidecar/test_sdk_loop.py
The claude-agent-sdk is NOT required: sessions are faked via session_factory."""
import asyncio
import os
import sys
import tempfile
import threading
import time

import sdk_loop

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


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


class FakeBridge:
    def __init__(self, tool_results=()):
        self.tool_results = list(tool_results)
        self.tool_calls = []
        self.narrations = []

    def call(self, command, timeout):
        if command["kind"] == "describe":
            return dict(DESCRIBE)
        if command["kind"] == "narrate":
            self.narrations.append(command["text"])
            return {"ok": True}
        if command["kind"] == "tool":
            self.tool_calls.append(command)
            if not self.tool_results:
                return None
            return self.tool_results.pop(0)
        return {"ok": False, "error": "unexpected"}


def fake_session(events):
    """session_factory returning a canned async stream of normalized events."""
    captured = []

    def factory(spec):
        captured.append(spec)

        async def stream():
            for ev in events:
                yield ev

        return stream()

    factory.captured = captured
    return factory


def _wait_done(runner, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        st = runner.status()
        if st.get("state") in ("done", "error"):
            return st
        time.sleep(0.01)
    return runner.status()


def main():
    fails = 0
    tmp = tempfile.mkdtemp()

    # --- happy path: two assistant turns then a result ---
    factory = fake_session([
        {"kind": "assistant", "text": "working on it", "tool_uses": [{"name": "mcp__studio__make_part", "input": {}}]},
        {"kind": "assistant", "text": "all done\nFACTORY_BUILD_JSON: {\"ok\": true}", "tool_uses": []},
        {"kind": "result", "subtype": "success", "result": None, "usage": {"output_tokens": 5}, "total_cost_usd": 0.0},
    ])
    bridge = FakeBridge()
    r = sdk_loop.SdkLoopRunner(bridge, session_factory=factory, loops_dir=tmp, sleep=lambda s: None)
    r.start("build a part")
    st = _wait_done(r)
    fails += _check("completes done", st["state"] == "done")
    fails += _check("result is last assistant text verbatim (sentinel intact)",
                    st["result"] == "all done\nFACTORY_BUILD_JSON: {\"ok\": true}")
    fails += _check("iteration counts assistant turns", st["iteration"] == 2)
    fails += _check("usage recorded", st.get("usage", {}).get("output_tokens") == 5)
    fails += _check("cost merged into usage", st.get("usage", {}).get("total_cost_usd") == 0.0)
    spec = factory.captured[0]
    fails += _check("system prompt = describe instructions", spec["system_prompt"] == "BE EXCELLENT.")
    fails += _check("prompt passed through", spec["prompt"] == "build a part")
    fails += _check("max_turns from describe", spec["max_turns"] == 10)
    fails += _check("model from describe", spec["model"] == "claude-test")
    fails += _check("bridge tool present in defs",
                    any(d["name"] == "make_part" for d in spec["tool_defs"]))
    fails += _check("narrated assistant text", any("working on it" in n for n in bridge.narrations))

    # --- double start raises ---
    gate = threading.Event()

    def gated_factory(spec):
        async def stream():
            await asyncio.to_thread(gate.wait)
            yield {"kind": "result", "subtype": "success", "result": "x", "usage": None, "total_cost_usd": None}

        return stream()

    r2 = sdk_loop.SdkLoopRunner(FakeBridge(), session_factory=gated_factory, loops_dir=tmp, sleep=lambda s: None)
    r2.start("one")
    try:
        r2.start("two")
        raised = False
    except sdk_loop.agent_loop.LoopError:
        raised = True
    gate.set()
    _wait_done(r2)
    fails += _check("double start raises LoopError", raised)

    # --- describe timeout -> error state, never wedged ---
    class DeadBridge:
        def call(self, command, timeout):
            return {"_timeout": True, "dispatched": False}

    r3 = sdk_loop.SdkLoopRunner(DeadBridge(), session_factory=fake_session([]), loops_dir=tmp, sleep=lambda s: None)
    r3.start("hello")
    st = _wait_done(r3)
    fails += _check("describe timeout -> error", st["state"] == "error" and "describe" in st["error"])

    # --- session factory crash -> error state, never wedged ---
    def boom(spec):
        raise RuntimeError("sdk not installed")

    r4 = sdk_loop.SdkLoopRunner(FakeBridge(), session_factory=boom, loops_dir=tmp, sleep=lambda s: None)
    r4.start("hello")
    st = _wait_done(r4)
    fails += _check("factory crash -> error state", st["state"] == "error")

    # --- tool defs: exclusion, schema fix, handlers ---
    raw_tools = [
        {"name": "make_part", "description": "d", "input_schema": {"type": "object", "properties": []}},
        {"name": "web_search", "type": "web_search_20250305"},
        {"name": "web_fetch", "type": "web_fetch_20250910"},
    ]
    bridge = FakeBridge(tool_results=[{
        "ok": True, "isError": False, "banner": "ctx",
        "content": [
            {"type": "text", "text": "made it"},
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AA=="}},
        ],
    }])
    tool_events = []
    defs = sdk_loop.build_tool_defs(raw_tools, bridge, None, lambda n, i: tool_events.append(n))
    fails += _check("web tools excluded", [d["name"] for d in defs] == ["make_part"])
    fails += _check("[] properties fixed to {}", defs[0]["input_schema"]["properties"] == {})

    out = asyncio.run(defs[0]["handler"]({"size": 4}))
    fails += _check("bridge got raw-mode tool call",
                    bridge.tool_calls[-1] == {"kind": "tool", "tool": "make_part", "input": {"size": 4}, "raw": True})
    fails += _check("on_tool fired", tool_events == ["make_part"])
    blocks = out["content"]
    fails += _check("banner text block first", blocks[0] == {"type": "text", "text": "ctx"})
    fails += _check("text block passthrough", blocks[1] == {"type": "text", "text": "made it"})
    fails += _check("image converted to MCP shape",
                    blocks[2] == {"type": "image", "data": "AA==", "mimeType": "image/png"})
    fails += _check("no error flag on success", "is_error" not in out)

    # --- bridge timeout -> guidance text + is_error ---
    bridge2 = FakeBridge(tool_results=[])  # empty -> FakeBridge returns None (timeout)
    defs2 = sdk_loop.build_tool_defs(raw_tools[:1], bridge2, None, lambda n, i: None)
    out2 = asyncio.run(defs2[0]["handler"]({}))
    fails += _check("timeout guidance ridden through",
                    out2["is_error"] is True and "bridge timeout" in out2["content"][0]["text"])

    # --- local tools dispatch sidecar-side ---
    local_calls = []
    local = {
        "schemas": [{"name": "read_source", "description": "d", "input_schema": {"type": "object"}}],
        "dispatch": lambda name, args: (local_calls.append((name, args)) or ("file body", False)),
    }
    defs3 = sdk_loop.build_tool_defs(raw_tools[:1], FakeBridge(), local, lambda n, i: None)
    names = [d["name"] for d in defs3]
    fails += _check("local schema merged", "read_source" in names and "make_part" in names)
    local_def = next(d for d in defs3 if d["name"] == "read_source")
    out3 = asyncio.run(local_def["handler"]({"path": "x.py"}))
    fails += _check("local dispatched sidecar-side", local_calls == [("read_source", {"path": "x.py"})])
    fails += _check("local text result", out3["content"] == [{"type": "text", "text": "file body"}])

    def _boom(name, args):
        raise RuntimeError("nope")

    defs4 = sdk_loop.build_tool_defs([], FakeBridge(), {"schemas": local["schemas"], "dispatch": _boom}, lambda n, i: None)
    out4 = asyncio.run(defs4[0]["handler"]({}))
    fails += _check("local crash -> is_error, loop survives",
                    out4["is_error"] is True and "crashed" in out4["content"][0]["text"])

    print(("FAILURES: %d" % fails) if fails else "ALL PASS")
    return fails


if __name__ == "__main__":
    sys.exit(min(main(), 1))
