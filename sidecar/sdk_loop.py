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
import copy
import json
import os
import threading
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


def _bridge_tool_handler(bridge, name, on_tool, lock):
    async def handler(args):
        on_tool(name, args)

        def locked_call():
            # single-slot bridge discipline (spec contract #7): the SDK may dispatch tools
            # concurrently; Store.submit overwrites the pending slot, so bridge calls must
            # serialize.
            with lock:
                return bridge.call(
                    {"kind": "tool", "tool": name, "input": args or {}, "raw": True},
                    agent_loop.TOOL_TIMEOUT,
                )

        bridge_result = await asyncio.to_thread(locked_call)
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
    # threading.Lock, NOT asyncio.Lock: the fallback-retry loop creates a fresh event loop
    # per attempt via repeated asyncio.run, and asyncio primitives must not span loops.
    bridge_lock = threading.Lock()
    tools = agent_loop.fix_luau_empty_objects(copy.deepcopy([t for t in describe_tools if isinstance(t, dict)]))
    defs = []
    for t in tools:
        name = str(t.get("name"))
        if name in ("web_search", "web_fetch"):  # Claude Code natives replace these
            continue
        defs.append({
            "name": name,
            "description": str(t.get("description") or ""),
            "input_schema": t.get("input_schema") or {"type": "object", "properties": {}},
            "handler": _bridge_tool_handler(bridge, name, on_tool, bridge_lock),
        })
    local = local_tools or {}
    if isinstance(local.get("schemas"), list) and local.get("dispatch"):
        for t in agent_loop.fix_luau_empty_objects(copy.deepcopy([s for s in local["schemas"] if isinstance(s, dict)])):
            name = str(t.get("name"))
            defs.append({
                "name": name,
                "description": str(t.get("description") or ""),
                "input_schema": t.get("input_schema") or {"type": "object", "properties": {}},
                "handler": _local_tool_handler(local["dispatch"], name, on_tool),
            })
    return defs


def _child_env(base_env):
    """Subscription-only env for the SDK subprocess: OAuth token required, API key scrubbed
    (an ANTHROPIC_API_KEY silently overrides subscription auth and bills per-token).
    T0 spike (sidecar/_spike_sdk.py FINDINGS): CLI keychain auth does NOT reach standalone
    SDK subprocesses on this machine, so the token is a hard requirement."""
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
    normalizes SDK messages to the event dicts _consume expects. Failure behavior per the
    T0 spike: the SDK RAISES out of query() iteration and a terminal ResultMessage is not
    guaranteed — exceptions must propagate to the runner's classifier, never be swallowed."""
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
