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

    # --- concurrent handlers serialize on the bridge (single-slot discipline) ---
    class SlowBridge(FakeBridge):
        def __init__(self):
            super().__init__()
            self.active = 0
            self.max_active = 0

        def call(self, command, timeout):
            if command["kind"] == "tool":
                self.active += 1
                self.max_active = max(self.max_active, self.active)
                time.sleep(0.05)
                self.active -= 1
                self.tool_calls.append(command)
                return {"ok": True, "isError": False, "banner": "", "content": "done"}
            return super().call(command, timeout)

    sb = SlowBridge()
    two_tools = [
        {"name": "tool_a", "description": "d", "input_schema": {"type": "object"}},
        {"name": "tool_b", "description": "d", "input_schema": {"type": "object"}},
    ]
    defs5 = sdk_loop.build_tool_defs(two_tools, sb, None, lambda n, i: None)

    async def both():
        await asyncio.gather(defs5[0]["handler"]({}), defs5[1]["handler"]({}))

    asyncio.run(both())
    fails += _check("concurrent bridge handlers serialized", sb.max_active == 1 and len(sb.tool_calls) == 2)

    # --- content-shape coverage: plain string, error-with-content, deepcopy, clean local error ---
    bridge3 = FakeBridge(tool_results=[{"ok": True, "isError": False, "banner": "", "content": "plain"}])
    defs6 = sdk_loop.build_tool_defs(two_tools[:1], bridge3, None, lambda n, i: None)
    out5 = asyncio.run(defs6[0]["handler"]({}))
    fails += _check("plain-string content -> text block", out5["content"] == [{"type": "text", "text": "plain"}])

    bridge4 = FakeBridge(tool_results=[{"ok": False, "banner": "", "content": "bad thing"}])
    defs7 = sdk_loop.build_tool_defs(two_tools[:1], bridge4, None, lambda n, i: None)
    out6 = asyncio.run(defs7[0]["handler"]({}))
    fails += _check("non-timeout error propagates is_error",
                    out6.get("is_error") is True and out6["content"][0]["text"] == "bad thing")

    pristine = [{"name": "tool_a", "description": "d", "input_schema": {"type": "object", "properties": []}}]
    sdk_loop.build_tool_defs(pristine, FakeBridge(), None, lambda n, i: None)
    fails += _check("caller schema not mutated (deepcopy)", pristine[0]["input_schema"]["properties"] == [])

    local_warn = {
        "schemas": [{"name": "warn_tool", "description": "d", "input_schema": {"type": "object"}}],
        "dispatch": lambda name, args: ("warned", True),
    }
    defs8 = sdk_loop.build_tool_defs([], FakeBridge(), local_warn, lambda n, i: None)
    out7 = asyncio.run(defs8[0]["handler"]({}))
    fails += _check("clean local error path sets is_error",
                    out7.get("is_error") is True and out7["content"] == [{"type": "text", "text": "warned"}])

    # --- wall clock: hanging stream -> error, never wedged ---
    def hanging_factory(spec):
        async def stream():
            await asyncio.sleep(3600)
            yield {"kind": "result", "subtype": "success", "result": "x", "usage": None, "total_cost_usd": None}

        return stream()

    saved_cap = sdk_loop.agent_loop.WALL_CLOCK_CAP
    sdk_loop.agent_loop.WALL_CLOCK_CAP = 0.2
    try:
        r5 = sdk_loop.SdkLoopRunner(FakeBridge(), session_factory=hanging_factory, loops_dir=tmp, sleep=lambda s: None)
        r5.start("hang")
        st = _wait_done(r5, timeout=5.0)
        fails += _check("wall clock kills a hung session", st["state"] == "error" and "wall-clock" in st["error"])
    finally:
        sdk_loop.agent_loop.WALL_CLOCK_CAP = saved_cap

    # --- max-turns termination gets the legacy suffix ---
    factory6 = fake_session([
        {"kind": "assistant", "text": "partial work", "tool_uses": []},
        {"kind": "result", "subtype": "error_max_turns", "result": None, "usage": None,
         "total_cost_usd": None, "is_error": True},
    ])
    r6 = sdk_loop.SdkLoopRunner(FakeBridge(), session_factory=factory6, loops_dir=tmp, sleep=lambda s: None)
    r6.start("big job", max_iterations=1)
    st = _wait_done(r6)
    fails += _check("capped run is done (not error) with suffix",
                    st["state"] == "done" and st["result"].startswith("partial work")
                    and "iteration cap reached" in st["result"])

    # --- error result subtype -> error state ---
    factory7 = fake_session([
        {"kind": "result", "subtype": "error_during_execution", "result": "boom", "usage": None,
         "total_cost_usd": None, "is_error": True},
    ])
    r7 = sdk_loop.SdkLoopRunner(FakeBridge(), session_factory=factory7, loops_dir=tmp, sleep=lambda s: None)
    r7.start("job")
    st = _wait_done(r7)
    fails += _check("error subtype -> error state", st["state"] == "error" and "error_during_execution" in st["error"])

    # --- rate-limit session error -> model fallback retry (fresh session) ---
    attempts = []

    def flaky_factory(spec):
        attempts.append(spec["model"])
        if len(attempts) == 1:
            raise RuntimeError("HTTP 429 rate limit exceeded")

        async def stream():
            yield {"kind": "assistant", "text": "recovered", "tool_uses": []}
            yield {"kind": "result", "subtype": "success", "result": None, "usage": None, "total_cost_usd": None}

        return stream()

    r8 = sdk_loop.SdkLoopRunner(FakeBridge(), session_factory=flaky_factory, loops_dir=tmp, sleep=lambda s: None)
    r8.start("job")
    st = _wait_done(r8)
    fails += _check("rate-limit falls back to next model",
                    st["state"] == "done" and attempts == ["claude-test", "claude-opus-4-8"])

    # --- transcript JSONL: same event names as legacy ---
    files = sorted(os.listdir(tmp))
    fails += _check("transcripts written", len(files) >= 1)
    with open(os.path.join(tmp, files[0]), encoding="utf-8") as fh:
        events = [__import__("json").loads(line)["event"] for line in fh if line.strip()]
    fails += _check("transcript has start/assistant_text/done shape",
                    "start" in events and "assistant_text" in events and ("done" in events or "error" in events))

    # --- child env hygiene ---
    base = {"PATH": "p", "ANTHROPIC_API_KEY": "sk-oops", "CLAUDE_CODE_OAUTH_TOKEN": "tok"}
    env = sdk_loop._child_env(base)
    fails += _check("API key overridden to empty (SDK merges env over os.environ)",
                    env.get("ANTHROPIC_API_KEY") == "")
    merged = {**base, **env}  # simulate the SDK's {**os.environ, **options.env} child-env merge
    fails += _check("key neutralized after SDK-style merge", merged["ANTHROPIC_API_KEY"] == "")
    fails += _check("oauth token kept", env["CLAUDE_CODE_OAUTH_TOKEN"] == "tok")
    fails += _check("PATH kept", env["PATH"] == "p")
    try:
        sdk_loop._child_env({"PATH": "p"})
        raised = False
    except sdk_loop.agent_loop.LoopError:
        raised = True
    fails += _check("missing oauth token raises LoopError", raised)
    env2 = sdk_loop._child_env({"PATH": "p", "CLAUDE_CODE_OAUTH_TOKEN": "tok",
                                "STUDIO_AGENT_SDK_BASE_URL": "http://proxy:1"})
    fails += _check("break-glass base url mapped", env2.get("ANTHROPIC_BASE_URL") == "http://proxy:1")

    # --- schema normalization: no top-level "properties" would trip the SDK's _build_schema
    # verbatim-pass gate (needs "type" AND "properties") and get mangled as a {param: type} map ---
    bare = [{"name": "bare_tool", "description": "d", "input_schema": {"type": "object"}}]
    defs9 = sdk_loop.build_tool_defs(bare, FakeBridge(), None, lambda n, i: None)
    fails += _check("schema without properties normalized",
                    defs9[0]["input_schema"].get("properties") == {}
                    and defs9[0]["input_schema"].get("type") == "object")

    print(("FAILURES: %d" % fails) if fails else "ALL PASS")
    return fails


if __name__ == "__main__":
    sys.exit(min(main(), 1))
