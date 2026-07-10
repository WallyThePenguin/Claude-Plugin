# SP1 — Agent SDK Loop Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the headless factory/forever loop on the official Claude Agent SDK (subscription auth) behind a `STUDIO_AGENT_LOOP=sdk|legacy` flag, preserving every `LoopRunner` contract so `factory.py`/`forever.py` never notice.

**Architecture:** New `sidecar/sdk_loop.py` defines `SdkLoopRunner(agent_loop.LoopRunner)` — inherits `start()` validation, `status()`, crash guard, and JSONL transcripts; overrides `_run_inner` to drive an async Claude Agent SDK session instead of the hand-rolled Messages-API loop. Bridge tools are generated at run time from the `describe` handshake into an in-process MCP server whose handlers dispatch through the existing `BridgeCaller` (via `asyncio.to_thread` so the event loop never blocks). A `session_factory` seam (mirroring legacy `send_factory`) yields **normalized event dicts**, so all unit tests run without the SDK installed.

**Tech Stack:** Python 3.10+ stdlib + `claude-agent-sdk` (only imported inside the real session factory); Claude Code CLI bundled by the SDK; auth via `CLAUDE_CODE_OAUTH_TOKEN`. Spec: `docs/superpowers/specs/2026-07-10-sp1-agent-sdk-loop-swap-design.md`.

**Conventions:** tests are dependency-free scripts like `sidecar/test_agent_loop.py` (`_check`/`main`, run `python sidecar/test_sdk_loop.py`, exit code = fail count). Commit prefix `feat(sidecar)`/`test(sidecar)`/`docs`.

---

### Task 0: Environment setup (operator)

**Files:** none (environment only)

- [ ] **Step 1: Install the SDK**

```bash
pip install claude-agent-sdk
python -c "import claude_agent_sdk; print(claude_agent_sdk.__version__)"
```
Expected: a version prints (0.x). If import fails, stop — nothing else can proceed.

- [ ] **Step 2: Mint the subscription token**

In a terminal where `claude` is logged in (Claude Code CLI):
```bash
claude setup-token
```
Copy the printed token. Set it for the sidecar (PowerShell, persistent for user):
```powershell
[Environment]::SetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN", "<token>", "User")
```

- [ ] **Step 3: Verify no API-key override exists**

```powershell
[Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User"); [Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "Machine")
```
Expected: both empty. If set, remove — an API key silently overrides subscription auth and bills per-token. (The code also scrubs it from the child env; this is belt-and-braces.)

---

### Task 1: T0 spike — verify the five risk items against the real SDK

**Files:**
- Create: `sidecar/_spike_sdk.py` (underscore prefix = not shipped, matches `_repro_verify.py`)

- [ ] **Step 1: Write the spike script**

```python
"""_spike_sdk.py — T0 spike for the SP1 SDK loop swap. Run: python sidecar/_spike_sdk.py
Verifies against the REAL SDK + subscription: (R1) big system prompt survives on Windows,
(R3) max_turns semantics, (R4) sentinel verbatim in result, (R5) mcp__ tool naming works,
image tool round-trip, auth uses subscription (no ANTHROPIC_API_KEY), is_error key shape.
Prints PASS/FAIL lines; eyeball + paste results into the plan checklist."""
import asyncio
import os

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    create_sdk_mcp_server,
    query,
    tool,
)

PNG_1PX = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
    "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)

CALLS = []


@tool("look_at_scene", "Returns a screenshot of the current scene", {})
async def look_at_scene(args):
    CALLS.append(("look_at_scene", args))
    return {
        "content": [
            {"type": "text", "text": "screenshot follows"},
            {"type": "image", "data": PNG_1PX, "mimeType": "image/png"},
        ]
    }


@tool("broken_tool", "Always fails, for is_error shape check", {})
async def broken_tool(args):
    CALLS.append(("broken_tool", args))
    return {"content": [{"type": "text", "text": "deliberate failure"}], "is_error": True}


async def main():
    assert os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"), "CLAUDE_CODE_OAUTH_TOKEN not set"
    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)  # subscription-only

    # R1: a big system prompt (~30KB, the size of real describe.instructions)
    big_rules = "RULE: always be concise. " * 1200
    system_prompt = big_rules + (
        "\nTool names are prefixed mcp__studio__ — e.g. call mcp__studio__look_at_scene "
        "when asked to look. When asked for a verdict, end your reply with exactly "
        "FACTORY_SPIKE_JSON: {\"ok\": true}"
    )
    server = create_sdk_mcp_server(name="studio", version="1.0.0", tools=[look_at_scene, broken_tool])
    options = ClaudeAgentOptions(
        system_prompt=system_prompt,
        mcp_servers={"studio": server},
        allowed_tools=["mcp__studio__look_at_scene", "mcp__studio__broken_tool"],
        disallowed_tools=["Read", "Write", "Edit", "Bash", "Glob", "Grep", "WebSearch", "WebFetch"],
        permission_mode="bypassPermissions",
        max_turns=6,
        env=env,
        setting_sources=[],
    )
    assistants = 0
    final_text = ""
    result_msg = None
    async for msg in query(
        prompt=(
            "Look at the scene with your tool, describe the image size in one short sentence, "
            "then give your verdict."
        ),
        options=options,
    ):
        if isinstance(msg, AssistantMessage):
            assistants += 1
            texts = [b.text for b in msg.content if isinstance(b, TextBlock)]
            tools_used = [b.name for b in msg.content if isinstance(b, ToolUseBlock)]
            if texts:
                final_text = "\n".join(texts)
            print(f"[assistant #{assistants}] tools={tools_used} text={' '.join(texts)[:120]!r}")
        elif isinstance(msg, ResultMessage):
            result_msg = msg

    print("PASS: auth+big system prompt (R1)" if assistants else "FAIL: no assistant messages (R1/auth)")
    print("PASS: tool called (R5 naming)" if any(c[0] == "look_at_scene" for c in CALLS) else "FAIL: tool never called (R5)")
    print("PASS: sentinel verbatim (R4)" if "FACTORY_SPIKE_JSON" in final_text else f"FAIL: sentinel missing (R4): {final_text!r}")
    if result_msg is not None:
        print(f"result.subtype={getattr(result_msg, 'subtype', None)!r} num_turns={getattr(result_msg, 'num_turns', None)} "
              f"cost={getattr(result_msg, 'total_cost_usd', None)} usage={getattr(result_msg, 'usage', None)}")
        rt = getattr(result_msg, "result", None)
        print("PASS: ResultMessage.result carries final text" if rt and "FACTORY_SPIKE_JSON" in rt
              else f"NOTE: ResultMessage.result={rt!r} — runner must use last-assistant-text instead")
    else:
        print("FAIL: no ResultMessage received")
    print(f"R3 calibration: assistants={assistants} vs ResultMessage.num_turns above — record the ratio")


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 2: Run it**

```bash
python sidecar/_spike_sdk.py
```
Expected: `[assistant #...]` lines, then PASS lines for auth/tool/sentinel, a `result.subtype='success'` line with usage populated. If the image tool errors, the model describes failure — record it.

- [ ] **Step 3: Record findings in the script header**

Append a `# FINDINGS <date>:` comment block to `_spike_sdk.py` recording: (a) big-system-prompt OK or argv failure (R1), (b) `num_turns` vs assistant count (R3), (c) whether `ResultMessage.result` was verbatim (R4), (d) exact `is_error` behavior, (e) any `claude.exe` left running afterwards (`tasklist | findstr claude`). If R1 FAILED: the runner must deliver instructions as the first user message instead — note it; Task 6 has the fallback branch.

- [ ] **Step 4: Commit**

```bash
git add sidecar/_spike_sdk.py
git commit -m "feat(sidecar): SDK loop spike — verify auth, system-prompt size, naming, sentinels (SP1 T0)"
```

---

### Task 2: `SdkLoopRunner` skeleton — lifecycle over a fake session

**Files:**
- Create: `sidecar/sdk_loop.py`
- Create: `sidecar/test_sdk_loop.py`

- [ ] **Step 1: Write the failing tests**

```python
"""Dependency-free tests for the SDK-backed loop. Run: python sidecar/test_sdk_loop.py
The claude-agent-sdk is NOT required: sessions are faked via session_factory."""
import asyncio
import os
import sys
import tempfile
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
    spec = factory.captured[0]
    fails += _check("system prompt = describe instructions", spec["system_prompt"] == "BE EXCELLENT.")
    fails += _check("prompt passed through", spec["prompt"] == "build a part")
    fails += _check("max_turns from describe", spec["max_turns"] == 10)
    fails += _check("model from describe", spec["model"] == "claude-test")
    fails += _check("bridge tool present in defs",
                    any(d["name"] == "make_part" for d in spec["tool_defs"]))
    fails += _check("narrated assistant text", any("working on it" in n for n in bridge.narrations))

    # --- double start raises ---
    slow = fake_session([{"kind": "result", "subtype": "success", "result": "x", "usage": None, "total_cost_usd": None}])
    r2 = sdk_loop.SdkLoopRunner(FakeBridge(), session_factory=slow, loops_dir=tmp, sleep=lambda s: None)
    r2.start("one")
    try:
        r2.start("two")
        raised = False
    except sdk_loop.agent_loop.LoopError:
        raised = True
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

    print(("FAILURES: %d" % fails) if fails else "ALL PASS")
    return fails


if __name__ == "__main__":
    sys.exit(min(main(), 1))
```

- [ ] **Step 2: Run to verify failure**

```bash
python sidecar/test_sdk_loop.py
```
Expected: `ModuleNotFoundError: No module named 'sdk_loop'`

- [ ] **Step 3: Write the implementation**

```python
"""sdk_loop.py — the Claude-Agent-SDK-backed loop runner (SP1).

Same public surface as agent_loop.LoopRunner (start/status), selected by
STUDIO_AGENT_LOOP=sdk|legacy in server.py. The SDK owns the agentic loop, retries,
caching, and context management; this runner owns: the describe handshake, dynamic
tool generation over the single-slot BridgeCaller, contract preservation (verbatim
final text for FACTORY_*_JSON sentinels, iteration/toolCalls status, JSONL transcripts,
wall-clock cap), and subscription-auth env hygiene.

Unit tests run WITHOUT claude-agent-sdk: the session_factory seam yields normalized
event dicts; the real factory (_sdk_session_factory) is the only place that imports
the SDK. Spec: docs/superpowers/specs/2026-07-10-sp1-agent-sdk-loop-swap-design.md
"""
import asyncio
import json
import os
import time

import agent_loop

ITERATION_CAP_SUFFIX = "\n(iteration cap reached — the work so far is applied; run again to continue)"


class SdkLoopRunner(agent_loop.LoopRunner):
    """LoopRunner subclass: inherits start() validation, status(), the crash guard
    (_run), and _transcript; replaces the loop body with an SDK session."""

    def __init__(self, bridge, session_factory=None, loops_dir=agent_loop.LOOPS_DIR, sleep=time.sleep):
        super().__init__(bridge, send_factory=lambda desc: None, loops_dir=loops_dir, sleep=sleep)
        self._session_factory = session_factory or _sdk_session_factory

    def _run_inner(self, run_id, prompt, max_iterations, model, local_tools=None):
        write = self._transcript(run_id)

        def emit(event, data):
            write(event, data)
            with self._lock:
                self._status["events"] = int(self._status.get("events") or 0) + 1
                if event in ("status", "assistant_text"):
                    recent = self._status.setdefault("recent", [])
                    recent.append(str(data)[:300])
                    del recent[:-6]

        def fail(message):
            emit("error", message)
            self._set(state="error", error=message)

        emit("start", {"prompt": prompt, "runner": "sdk"})
        describe = self._bridge.call({"kind": "describe"}, agent_loop.DESCRIBE_TIMEOUT)
        if describe is None or describe.get("_timeout"):
            return fail(
                "the plugin bridge did not answer `describe` — is Studio open with the dev "
                "bridge active (and no other client driving /agent)?"
            )
        if not describe.get("ok"):
            return fail("describe failed: " + str(describe.get("error")))

        max_iter = int(max_iterations or describe.get("maxIterations") or 40)
        instructions = str(describe.get("instructions") or "")
        active_model = model or describe.get("model")
        fallbacks = [m for m in agent_loop.MODEL_FALLBACKS if m != active_model]

        def on_tool(name, tool_input):
            emit("tool_use", {"name": name, "input": tool_input})
            with self._lock:
                self._status["toolCalls"] = int(self._status.get("toolCalls") or 0) + 1

        tool_defs = build_tool_defs(describe.get("tools") or [], self._bridge, local_tools, on_tool)

        while True:  # model-fallback retry loop (fresh session per attempt)
            spec = {
                "prompt": prompt,
                "system_prompt": instructions,
                "tool_defs": tool_defs,
                "max_turns": max_iter,
                "model": active_model,
                "mechanic": bool(local_tools),
            }
            try:
                outcome = asyncio.run(self._consume(spec, emit))
            except Exception as exc:  # noqa: BLE001 — includes SDK/CLI process errors
                text = repr(exc)
                if _looks_rate_limited(text) and fallbacks:
                    active_model = fallbacks.pop(0)
                    emit("status", f"rate-limited — falling back to {active_model}")
                    continue
                return fail(f"sdk session error: {text}")
            break

        if outcome["state"] == "error":
            return fail(outcome["error"])
        self._set(state="done", result=outcome["result"], usage=outcome.get("usage"))
        emit("done", {"iterations": outcome["iterations"], "capped": outcome.get("capped", False)})

    async def _consume(self, spec, emit):
        """Drive one SDK session to completion under the wall clock. Returns
        {state, result, iterations, usage, capped} or {state:'error', error}."""
        deadline = time.monotonic() + agent_loop.WALL_CLOCK_CAP
        stream = self._session_factory(spec)
        iterations = 0
        final_text = ""
        usage = None
        capped = False
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise asyncio.TimeoutError()
                try:
                    ev = await asyncio.wait_for(stream.__anext__(), timeout=remaining)
                except StopAsyncIteration:
                    break
                if ev["kind"] == "assistant":
                    iterations += 1
                    self._set(iteration=iterations, model=spec["model"])
                    if ev.get("text"):
                        final_text = ev["text"]
                        emit("assistant_text", final_text)
                        await self._narrate(final_text)
                elif ev["kind"] == "result":
                    usage = dict(ev.get("usage") or {})
                    usage["total_cost_usd"] = ev.get("total_cost_usd")
                    if str(ev.get("subtype") or "") not in ("success",):
                        if "max_turn" in str(ev.get("subtype") or ""):
                            capped = True
                        elif ev.get("is_error"):
                            return {"state": "error",
                                    "error": f"sdk result [{ev.get('subtype')}]: {ev.get('result')}"}
                    if not final_text and ev.get("result"):
                        final_text = str(ev["result"])
        except asyncio.TimeoutError:
            await _aclose_quietly(stream)
            return {"state": "error", "error": f"wall-clock cap hit after {iterations} iterations"}
        result = final_text + (ITERATION_CAP_SUFFIX if capped else "")
        return {"state": "done", "result": result, "iterations": iterations, "usage": usage, "capped": capped}

    async def _narrate(self, text):
        """Live commentary into Studio Output — best-effort, off the event loop."""
        try:
            snippet = " ".join(text.split())
            if len(snippet) > 240:
                snippet = snippet[:240] + "..."
            await asyncio.to_thread(self._bridge.call, {"kind": "narrate", "text": "agent: " + snippet}, 15)
        except Exception:  # noqa: BLE001
            pass


async def _aclose_quietly(stream):
    try:
        await stream.aclose()
    except Exception:  # noqa: BLE001
        pass


def _looks_rate_limited(text):
    low = str(text).lower()
    return "429" in low or "rate limit" in low or "rate_limit" in low or "cooling down" in low or "usage limit" in low


def build_tool_defs(describe_tools, bridge, local_tools, on_tool):
    raise NotImplementedError  # Task 3


def _sdk_session_factory(spec):
    raise NotImplementedError  # Task 6
```

- [ ] **Step 4: Adjust the skeleton so Task 2 tests pass without Task 3**

Replace the `build_tool_defs` stub with the minimal version (Task 3 replaces it):

```python
def build_tool_defs(describe_tools, bridge, local_tools, on_tool):
    """Minimal placeholder shape until Task 3: name/description/schema only."""
    return [
        {"name": str(t.get("name")), "description": str(t.get("description") or ""),
         "input_schema": t.get("input_schema") or {"type": "object", "properties": {}},
         "handler": None}
        for t in describe_tools
        if isinstance(t, dict) and str(t.get("name")) not in ("web_search", "web_fetch")
    ]
```

- [ ] **Step 5: Run tests to verify pass**

```bash
python sidecar/test_sdk_loop.py
```
Expected: `ALL PASS`

- [ ] **Step 6: Regression-check the legacy suite**

```bash
python sidecar/test_agent_loop.py
```
Expected: `ALL PASS` (nothing in agent_loop.py changed)

- [ ] **Step 7: Commit**

```bash
git add sidecar/sdk_loop.py sidecar/test_sdk_loop.py
git commit -m "feat(sidecar): SdkLoopRunner skeleton — lifecycle, fallback, wall clock over fake sessions (SP1)"
```

---

### Task 3: Dynamic tool generation + bridge dispatch + content conversion

**Files:**
- Modify: `sidecar/sdk_loop.py` (replace `build_tool_defs`, add `_to_mcp_blocks`, `_bridge_tool_handler`, `_local_tool_handler`)
- Modify: `sidecar/test_sdk_loop.py` (append tests)

- [ ] **Step 1: Append the failing tests to `test_sdk_loop.py` `main()`** (before the final print)

```python
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
```

- [ ] **Step 2: Run to verify failure**

```bash
python sidecar/test_sdk_loop.py
```
Expected: FAILs on the new checks (placeholder `build_tool_defs` has no handlers / no schema fix).

- [ ] **Step 3: Implement in `sdk_loop.py`** (replace the placeholder `build_tool_defs`)

```python
def _to_mcp_blocks(content):
    """Anthropic tool_result content (str or block list) -> MCP content block list.
    Text passes through; base64 image sources become {type:'image', data, mimeType}."""
    if not isinstance(content, list):
        return [{"type": "text", "text": str(content)}]
    out = []
    for block in content:
        if not isinstance(block, dict):
            out.append({"type": "text", "text": str(block)})
        elif block.get("type") == "image" and isinstance(block.get("source"), dict):
            src = block["source"]
            out.append({"type": "image", "data": src.get("data"), "mimeType": src.get("media_type")})
        elif block.get("type") == "text":
            out.append({"type": "text", "text": str(block.get("text") or "")})
        else:
            out.append({"type": "text", "text": json.dumps(block)})
    return out


def _bridge_tool_handler(bridge, name, on_tool):
    async def handler(args):
        on_tool(name, args)
        bridge_result = await asyncio.to_thread(
            bridge.call, {"kind": "tool", "tool": name, "input": args or {}, "raw": True},
            agent_loop.TOOL_TIMEOUT,
        )
        # Reuse the legacy converter for banner/timeout-guidance/empty-Luau semantics,
        # then reshape its content for MCP.
        block = agent_loop._tool_result_block("x", bridge_result)
        out = {"content": _to_mcp_blocks(block["content"])}
        if block.get("is_error"):
            out["is_error"] = True
        return out

    return handler


def _local_tool_handler(dispatch, name, on_tool):
    async def handler(args):
        on_tool(name, args)
        try:
            text, is_err = await asyncio.to_thread(dispatch, name, args or {})
        except Exception as exc:  # noqa: BLE001 — a local tool must never kill the loop
            text, is_err = f"{name}: local tool crashed: {exc!r}", True
        out = {"content": [{"type": "text", "text": str(text)}]}
        if is_err:
            out["is_error"] = True
        return out

    return handler


def build_tool_defs(describe_tools, bridge, local_tools, on_tool):
    """Generate SDK tool definitions from the describe handshake + mechanic local tools.
    Each def: {name, description, input_schema, handler(async args -> MCP result)}."""
    tools = agent_loop.fix_luau_empty_objects([dict(t) for t in describe_tools if isinstance(t, dict)])
    defs = []
    for t in tools:
        name = str(t.get("name"))
        if name in ("web_search", "web_fetch"):  # Claude Code natives replace these
            continue
        defs.append({
            "name": name,
            "description": str(t.get("description") or ""),
            "input_schema": t.get("input_schema") or {"type": "object", "properties": {}},
            "handler": _bridge_tool_handler(bridge, name, on_tool),
        })
    local = local_tools or {}
    if isinstance(local.get("schemas"), list) and local.get("dispatch"):
        for t in agent_loop.fix_luau_empty_objects([dict(s) for s in local["schemas"] if isinstance(s, dict)]):
            name = str(t.get("name"))
            defs.append({
                "name": name,
                "description": str(t.get("description") or ""),
                "input_schema": t.get("input_schema") or {"type": "object", "properties": {}},
                "handler": _local_tool_handler(local["dispatch"], name, on_tool),
            })
    return defs
```

- [ ] **Step 4: Run tests to verify pass**

```bash
python sidecar/test_sdk_loop.py
```
Expected: `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add sidecar/sdk_loop.py sidecar/test_sdk_loop.py
git commit -m "feat(sidecar): dynamic SDK tool generation over BridgeCaller — images, timeouts, local tools (SP1)"
```

---

### Task 4: Wall clock, iteration-cap suffix, transcript shape

**Files:**
- Modify: `sidecar/test_sdk_loop.py` (append tests)
- Modify: `sidecar/sdk_loop.py` (only if a test exposes a gap — the Task 2 code should already satisfy these)

- [ ] **Step 1: Append the failing tests**

```python
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
```

- [ ] **Step 2: Run tests**

```bash
python sidecar/test_sdk_loop.py
```
Expected: `ALL PASS` if Task 2's `_consume` was implemented as written; fix any FAIL inline (the likely gap: `error_max_turns` must set `capped` without erroring — the Task 2 code checks `"max_turn" in subtype` **before** the `is_error` branch, which handles it).

- [ ] **Step 3: Commit**

```bash
git add sidecar/test_sdk_loop.py sidecar/sdk_loop.py
git commit -m "test(sidecar): SDK loop wall-clock, cap-suffix, transcript-shape coverage (SP1)"
```

---

### Task 5: Real session factory (`claude-agent-sdk` glue)

**Files:**
- Modify: `sidecar/sdk_loop.py` (replace `_sdk_session_factory` stub; add `_child_env`)
- Modify: `sidecar/test_sdk_loop.py` (append `_child_env` tests)

- [ ] **Step 1: Append the failing tests**

```python
    # --- child env hygiene ---
    base = {"PATH": "p", "ANTHROPIC_API_KEY": "sk-oops", "CLAUDE_CODE_OAUTH_TOKEN": "tok"}
    env = sdk_loop._child_env(base)
    fails += _check("API key scrubbed", "ANTHROPIC_API_KEY" not in env)
    fails += _check("oauth token kept", env["CLAUDE_CODE_OAUTH_TOKEN"] == "tok")
    fails += _check("PATH kept", env["PATH"] == "p")
    try:
        sdk_loop._child_env({"PATH": "p"})
        raised = False
    except sdk_loop.agent_loop.LoopError:
        raised = True
    fails += _check("missing oauth token raises LoopError", raised)
```

- [ ] **Step 2: Run to verify failure** — `python sidecar/test_sdk_loop.py` → FAIL (`_child_env` missing).

- [ ] **Step 3: Implement in `sdk_loop.py`** (replace the `_sdk_session_factory` stub)

```python
def _child_env(base_env):
    """Subscription-only env for the SDK subprocess: OAuth token required, API key scrubbed
    (an ANTHROPIC_API_KEY silently overrides subscription auth and bills per-token)."""
    env = dict(base_env)
    env.pop("ANTHROPIC_API_KEY", None)
    if not env.get("CLAUDE_CODE_OAUTH_TOKEN"):
        raise agent_loop.LoopError(
            "CLAUDE_CODE_OAUTH_TOKEN is not set — run `claude setup-token` and put it in the "
            "sidecar environment (see HANDOFF.md)"
        )
    base_url = env.get("STUDIO_AGENT_SDK_BASE_URL")  # break-glass proxy fallback
    if base_url:
        env["ANTHROPIC_BASE_URL"] = base_url
    return env


def _sdk_session_factory(spec):
    """The only SDK-touching code. Maps our tool defs + spec into a query() stream and
    normalizes SDK messages to the event dicts _consume expects."""
    from claude_agent_sdk import (  # imported lazily: unit tests never need the SDK
        AssistantMessage,
        ClaudeAgentOptions,
        ResultMessage,
        TextBlock,
        ToolUseBlock,
        create_sdk_mcp_server,
        query,
        tool,
    )

    sdk_tools = []
    for d in spec["tool_defs"]:
        sdk_tools.append(tool(d["name"], d["description"] or d["name"], d["input_schema"])(d["handler"]))
    server = create_sdk_mcp_server(name="studio", version="1.0.0", tools=sdk_tools)
    mcp_servers = {"studio": server}
    if spec.get("mechanic"):
        extra = os.environ.get("STUDIO_AGENT_MECHANIC_MCP")  # e.g. memtrace config JSON
        if extra:
            try:
                mcp_servers.update(json.loads(extra))
            except ValueError:
                pass  # bad JSON must not kill a run; surfaced by absence of the extra tools
    allowed = ["mcp__studio__" + d["name"] for d in spec["tool_defs"]] + ["WebSearch", "WebFetch"]
    system_prompt = spec["system_prompt"] + (
        "\n\nNOTE: your tools are exposed with an mcp__studio__ prefix — e.g. the tool called "
        "`capture` in these instructions is invoked as `mcp__studio__capture`."
    )
    options = ClaudeAgentOptions(
        system_prompt=system_prompt,
        mcp_servers=mcp_servers,
        allowed_tools=allowed,
        disallowed_tools=["Read", "Write", "Edit", "Bash", "Glob", "Grep", "NotebookEdit", "Agent", "Task"],
        permission_mode="bypassPermissions",
        max_turns=int(spec["max_turns"]),
        model=spec.get("model"),
        env=_child_env(os.environ),
        setting_sources=[],
        cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    )

    async def stream():
        async for msg in query(prompt=spec["prompt"], options=options):
            if isinstance(msg, AssistantMessage):
                texts = [b.text for b in msg.content if isinstance(b, TextBlock)]
                uses = [{"name": b.name, "input": b.input} for b in msg.content if isinstance(b, ToolUseBlock)]
                yield {"kind": "assistant", "text": "\n".join(texts), "tool_uses": uses}
            elif isinstance(msg, ResultMessage):
                yield {
                    "kind": "result",
                    "subtype": getattr(msg, "subtype", None),
                    "result": getattr(msg, "result", None),
                    "usage": getattr(msg, "usage", None),
                    "total_cost_usd": getattr(msg, "total_cost_usd", None),
                    "is_error": bool(getattr(msg, "is_error", False)),
                }

    return stream()
```

- [ ] **Step 4: Run tests** — `python sidecar/test_sdk_loop.py` → `ALL PASS` (the factory body is exercised by Task 7's live run, not unit tests).

- [ ] **Step 5: Reconcile with T0 findings**

Open `sidecar/_spike_sdk.py` FINDINGS. If R1 failed (argv limit): in `_sdk_session_factory`, move `system_prompt` content into the prompt as a leading block instead:
```python
    # R1 fallback (only if the spike showed argv failure):
    # options gets system_prompt=PREFIX_NOTE only, and
    # prompt = agent_loop.PREAMBLE_HEADER + spec["system_prompt"] + "\n\n---\n\n" + spec["prompt"]
```
If the spike showed a different `is_error`/schema-dict behavior, adjust `_local_tool_handler`/`tool()` usage to match and note it in the module docstring.

- [ ] **Step 6: Commit**

```bash
git add sidecar/sdk_loop.py sidecar/test_sdk_loop.py
git commit -m "feat(sidecar): real claude-agent-sdk session factory — subscription env, mcp server, normalization (SP1)"
```

---

### Task 6: Flag wiring in server.py

**Files:**
- Modify: `sidecar/sdk_loop.py` (add `select_loop_runner`)
- Modify: `sidecar/server.py:55` (one line)
- Modify: `sidecar/test_sdk_loop.py` (append tests)

- [ ] **Step 1: Append the failing tests**

```python
    # --- runner selection flag ---
    b = FakeBridge()
    r_legacy = sdk_loop.select_loop_runner(b, {"STUDIO_AGENT_LOOP": "legacy"})
    r_sdk = sdk_loop.select_loop_runner(b, {"STUDIO_AGENT_LOOP": "sdk"})
    r_default = sdk_loop.select_loop_runner(b, {})
    fails += _check("legacy flag -> LoopRunner", type(r_legacy) is sdk_loop.agent_loop.LoopRunner)
    fails += _check("sdk flag -> SdkLoopRunner", type(r_sdk) is sdk_loop.SdkLoopRunner)
    fails += _check("default is legacy until T2 passes", type(r_default) is sdk_loop.agent_loop.LoopRunner)
```

- [ ] **Step 2: Run to verify failure**, then implement in `sdk_loop.py`:

```python
def select_loop_runner(bridge, env=None):
    """STUDIO_AGENT_LOOP=sdk|legacy (default legacy until T2 signs off)."""
    env = os.environ if env is None else env
    if str(env.get("STUDIO_AGENT_LOOP", "legacy")).strip().lower() == "sdk":
        return SdkLoopRunner(bridge)
    return agent_loop.LoopRunner(bridge)
```

- [ ] **Step 3: Wire `server.py`** — replace line 55 (`LOOP = agent_loop.LoopRunner(_BRIDGE)`):

```python
import sdk_loop

LOOP = sdk_loop.select_loop_runner(_BRIDGE)  # STUDIO_AGENT_LOOP=sdk|legacy (default legacy)
```
(Place the `import sdk_loop` with the other imports at `server.py:43-50`.)

- [ ] **Step 4: Run both suites + the server's own tests**

```bash
python sidecar/test_sdk_loop.py
python sidecar/test_agent_loop.py
python sidecar/test_server.py
```
Expected: all `ALL PASS` (server still constructs a legacy runner by default).

- [ ] **Step 5: Commit**

```bash
git add sidecar/sdk_loop.py sidecar/server.py sidecar/test_sdk_loop.py
git commit -m "feat(sidecar): STUDIO_AGENT_LOOP flag selects sdk|legacy loop runner (SP1)"
```

---

### Task 7: T2 — live A/B factory cycle (operator + agent)

**Files:** none (runtime verification; findings recorded in Task 8's HANDOFF update)

- [ ] **Step 1: Baseline legacy run** — Studio open on a **fresh Baseplate** (test-session doctrine), sidecar running with the plugin bridge active:

```bash
curl -s -X POST http://127.0.0.1:8389/factory -H "Content-Type: application/json" -d "{\"rung\": \"<a proven rung id from factory/curriculum.json>\"}"
```
Poll `curl -s http://127.0.0.1:8389/factory/status` until `state=done`. Record: status (PASSED/FAILED/UNVERIFIED), staging file name in `sidecar/store/staging/`, wall time, and the transcript file in `sidecar/loops/`.

- [ ] **Step 2: SDK run** — stop the sidecar; restart it with the flag:

```powershell
$env:STUDIO_AGENT_LOOP = "sdk"; python sidecar/server.py
```
Repeat the same `POST /factory` with the same rung.

- [ ] **Step 3: Compare (the A/B gate)**

- Staging entry JSON has the identical schema and a sane verdict (`status`, `gate`, `evidence`, `artifactTrace`).
- The SDK transcript contains `assistant_text` events, `tool_use` events, and image evidence reached the model (VERIFY reasoning references what captures show).
- `GET /loop/status` after the run shows `usage` populated — record `total_cost_usd`/tokens vs. the legacy run's transcript length (R2 economics).
- No orphan `claude` processes: `tasklist | findstr claude` after the run.

- [ ] **Step 4: Rollback check** — restart the sidecar without the env var; `POST /loop` a trivial prompt; confirm the legacy path still works.

- [ ] **Step 5 (only if all above pass): T3 soak**

```bash
curl -s -X POST http://127.0.0.1:8389/forever -H "Content-Type: application/json" -d "{\"cycles\": 2}"
```
Watch `GET /forever/status` through 2 cycles: RETRO/AUTHOR stages complete, no wedged `running`, staging entries written, learnings appended.

---

### Task 8: Docs + default-flip decision

**Files:**
- Modify: `HANDOFF.md` (prepend a START HERE block)

- [ ] **Step 1: Prepend to `HANDOFF.md`**

```markdown
## START HERE (2026-07-XX) — headless loop can run on the Claude Agent SDK (SP1)

The factory/forever loop now runs on the official Claude Agent SDK (subscription auth) when
`STUDIO_AGENT_LOOP=sdk` (default remains `legacy`). Setup: `pip install claude-agent-sdk`;
`claude setup-token` -> CLAUDE_CODE_OAUTH_TOKEN in the sidecar env; ensure ANTHROPIC_API_KEY is
NOT set (it overrides subscription and bills per-token). Optional: STUDIO_AGENT_MECHANIC_MCP
(JSON mcp_servers dict, e.g. memtrace) attaches extra MCP servers to MECHANIC runs only;
STUDIO_AGENT_SDK_BASE_URL routes through a proxy (break-glass). T2 A/B results: <fill from Task 7>.
Spec: docs/superpowers/specs/2026-07-10-sp1-agent-sdk-loop-swap-design.md
Plan: docs/superpowers/plans/2026-07-10-sp1-agent-sdk-loop-swap.md
```
Replace `<fill from Task 7>` with the recorded A/B numbers and `2026-07-XX` with the actual date — do not commit the literal placeholder.

- [ ] **Step 2: Default-flip decision (operator)** — if T2/T3 passed and economics are acceptable, flip the default in `sdk_loop.select_loop_runner` (`"legacy"` → `"sdk"`) in a separate commit; otherwise leave `legacy` and file the blockers in `factory/tooling-issues.json`.

- [ ] **Step 3: Commit**

```bash
git add HANDOFF.md
git commit -m "docs: HANDOFF — SDK loop setup, flag, and T2 A/B results (SP1)"
```

---

## Self-review notes (already applied)

- Spec §2 items 1–8 map to Tasks 2/3/5/6; §3 contracts 1–11 are covered by tests in Tasks 2–4 (contracts 5/7/8 by construction: shared `BridgeCaller`, fresh session per `start()`, thread inside `start()`); §5 error handling → Tasks 2/4/5; §6 T0–T3 → Tasks 1/2–5/7; §7 rollout → Tasks 6/8; §8 risks → R1/R3/R4/R5 in Task 1, R2 in Task 7.
- Known deliberate deferrals: `emergency_trim`/`prune_images_keeping_last` are NOT ported (SDK owns context; spec §4 "retired", R2 measures the consequence). `is_context_length_error` handling is SDK-internal (auto-compaction).
- Type consistency: `session_factory(spec) -> async iterator` of `{"kind": "assistant"|"result", ...}` events used identically in Tasks 2, 4, 5; `build_tool_defs` def shape `{name, description, input_schema, handler}` consistent across Tasks 2 (placeholder), 3 (final), 5 (consumer).
