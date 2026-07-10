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
import time

import agent_loop

# Mirrors the inline suffix in agent_loop._run_inner — agent_loop.py stays untouched during
# SP1 (A/B + rollback integrity); unify when the legacy loop retires.
ITERATION_CAP_SUFFIX = "\n(iteration cap reached — the work so far is applied; run again to continue)"


class SdkLoopRunner(agent_loop.LoopRunner):
    """LoopRunner subclass: inherits start() validation, status(), the crash guard
    (_run), and _transcript; replaces the loop body with an SDK session."""

    def __init__(self, bridge, session_factory=None, loops_dir=agent_loop.LOOPS_DIR, sleep=time.sleep):
        super().__init__(bridge, send_factory=lambda desc: None, loops_dir=loops_dir, sleep=sleep)
        self._session_factory = session_factory or _sdk_session_factory

    # The describe/emit/fail block below deliberately duplicates agent_loop's (same rationale
    # as the ITERATION_CAP_SUFFIX comment above: agent_loop.py stays untouched during SP1).
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

        deadline = time.monotonic() + agent_loop.WALL_CLOCK_CAP
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
                outcome = asyncio.run(self._consume(spec, emit, deadline))
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

    async def _consume(self, spec, emit, deadline):
        """Drive one SDK session to completion under the wall clock. Returns
        {state, result, iterations, usage, capped} or {state:'error', error}."""
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
                    # tool_uses is informational-only in the event contract; toolCalls counting
                    # rides the on_tool handler callback (exercised by Task 3 handler tests +
                    # the T2 live run).
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
            # On 3.11+, asyncio.TimeoutError IS TimeoutError — a TimeoutError raised from INSIDE
            # the SDK stream (e.g. an underlying HTTP read timeout) would land here too. Only
            # classify as the wall-clock cap when the deadline has actually been reached;
            # otherwise let it propagate as an sdk session error via the caller's except.
            if deadline - time.monotonic() > 1.0:
                raise
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
    if "out of extra usage" in low:
        # Subscription window exhausted, not a per-model cooldown — fail fast, never cycle
        # fallback models (mirrors agent_loop.is_rate_limited + is_transient).
        return False
    # Token set to be calibrated against real SDK error strings during T2 (plan Task 7).
    return "429" in low or "rate limit" in low or "rate_limit" in low or "cooling down" in low or "quota" in low


def build_tool_defs(describe_tools, bridge, local_tools, on_tool):
    """Minimal placeholder shape until Task 3: name/description/schema only."""
    return [
        {"name": str(t.get("name")), "description": str(t.get("description") or ""),
         "input_schema": t.get("input_schema") or {"type": "object", "properties": {}},
         "handler": None}
        for t in describe_tools
        if isinstance(t, dict) and str(t.get("name")) not in ("web_search", "web_fetch")
    ]


def _sdk_session_factory(spec):
    raise NotImplementedError  # Task 6
