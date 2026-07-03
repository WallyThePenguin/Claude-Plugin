"""agent_loop.py — the sidecar-side agent loop (the loop-economics rework).

The in-Luau AgentLoop is correct but expensive: every model round-trip runs inside Studio via
HttpService and the whole loop is serialized through an attended Studio session. This module IS
that loop, in Python, running in the sidecar process: it calls the model directly (same proxy
endpoint the plugin uses) and dispatches every tool_use INTO Studio over the existing dev-bridge
/agent channel (raw mode), so Studio is reduced to hands while the brain runs out-of-process.

Contract parity with AgentLoop.luau (the verified rules):
- Instructions are delivered as a LEADING user/assistant preamble, never `system` (the proxy
  strips the system field — see MessageUtil.withSystemPreamble).
- Assistant content is echoed back verbatim; tool_use PRESENCE decides whether the turn
  continues; every tool_use gets exactly one tool_result in ONE following user message.
- Transient failures (transport / 408 409 429 / 5xx / 529 / "overloaded" / the cold-proxy
  "unknown provider for model" race) retry with capped exponential backoff; the subscription
  usage-window ("out of extra usage") does NOT retry.
- Keep-K image pruning before every send (references + captures both count).

Single-flight: the dev-bridge command queue is a single slot, so exactly one loop may run at a
time, and nothing else should drive /agent while it runs. server.py enforces the former.
"""

import json
import os
import re
import threading
import time
import urllib.error
import urllib.request

LOOPS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "loops")

PREAMBLE_HEADER = (
    "These are your operating instructions for this entire conversation. Follow them as your "
    "system prompt; the actual messages begin after your acknowledgement.\n\n"
)
PREAMBLE_ACK = "Understood. I'll follow these instructions throughout."

DESCRIBE_TIMEOUT = 15.0
TOOL_TIMEOUT = 240.0  # playtest tools legitimately take minutes
MODEL_TIMEOUT = 300.0
WALL_CLOCK_CAP = 45 * 60.0

RETRY_MAX_ATTEMPTS = 4
RETRY_BASE_DELAY = 2.0
RETRY_MAX_DELAY = 20.0


class LoopError(ValueError):
    """Client error — maps to HTTP 400/409."""


# ---- bridge adapter ---------------------------------------------------------


class BridgeCaller:
    """Submit a command to the in-process dev-bridge Store and poll for its result.
    The plugin's DevBridge tick (~1.5s) claims the single pending slot and posts the result."""

    def __init__(self, store, poll_interval: float = 0.25, sleep=time.sleep):
        self._store = store
        self._poll = poll_interval
        self._sleep = sleep

    def call(self, command: dict, timeout: float):
        """The result dict; on timeout a {"_timeout": True, "dispatched": bool} marker.
        dispatched=False means the command was reclaimed UNRUN (Studio never picked it up —
        safe to retry); dispatched=True means Studio claimed it and it may STILL be running
        (retrying a destructive tool could double-execute)."""
        cid = self._store.submit(dict(command))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self._store.pop_result(cid)  # consume — never park big results/keys
            if result is not None:
                return result
            self._sleep(self._poll)
        pending = self._store.take_pending()
        if pending is not None and pending.get("id") == cid:
            return {"_timeout": True, "dispatched": False}
        if pending is not None:  # someone else's command — put it back untouched
            self._store.requeue(pending)
        return {"_timeout": True, "dispatched": True}


# ---- model client -----------------------------------------------------------


class ModelClient:
    """POST /v1/messages against the proxy the plugin already uses. Never raises; returns the
    same result envelope shape as Anthropic.luau: {ok, data} or {ok:false, kind, status?, message}."""

    def __init__(self, base_url: str, proxy_key: str, timeout: float = MODEL_TIMEOUT):
        self._url = base_url.rstrip("/") + "/v1/messages"
        self._key = proxy_key
        self._timeout = timeout

    def send(self, body: dict) -> dict:
        if not self._key:
            return {"ok": False, "kind": "auth", "message": "proxy key not set in the plugin"}
        raw = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            self._url,
            data=raw,
            headers={
                "Authorization": "Bearer " + self._key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                payload = resp.read()
        except urllib.error.HTTPError as exc:  # non-2xx
            message = ""
            try:
                envelope = json.loads(exc.read().decode("utf-8", "replace"))
                message = ((envelope.get("error") or {}).get("message")) or ""
            except Exception:  # noqa: BLE001
                pass
            return {
                "ok": False,
                "kind": "http",
                "status": exc.code,
                "message": message or str(exc),
            }
        except Exception as exc:  # noqa: BLE001 — DNS/refused/timeout
            return {"ok": False, "kind": "transport", "message": str(exc)}
        try:
            return {"ok": True, "data": json.loads(payload.decode("utf-8"))}
        except ValueError:
            return {"ok": False, "kind": "decode", "message": "could not decode response body"}


# When the primary model's subscription credential rate-limits ("cooling down"), fall through this
# chain — rate limits are PER-MODEL on this account, so a different model keeps the loop running.
MODEL_FALLBACKS = ["claude-opus-4-8", "claude-opus-4-7"]


def is_rate_limited(res: dict) -> bool:
    """The model's credential is throttled/cooling down (429 or CLIProxyAPI's cooldown message).
    Distinct from a plain transient 5xx — the SAME model won't recover soon, so switch models."""
    if res.get("kind") != "http":
        return False
    if res.get("status") == 429:
        return True
    msg = str(res.get("message") or "").lower()
    return "cooling down" in msg or "rate limit" in msg or "rate_limit" in msg or "quota" in msg


def is_context_length_error(res: dict) -> bool:
    """Port of Compactor.isContextLengthError — the request itself is too big to send."""
    if res.get("kind") != "http":
        return False
    msg = str(res.get("message") or "").lower()
    return (
        "prompt is too long" in msg
        or "input length" in msg
        or "context limit" in msg
        or ("exceed" in msg and ("context" in msg or "token" in msg))
    )


def is_transient(res: dict) -> bool:
    """Port of Retry.isTransient — what retries on the SAME model. A rate-limit (429 / cooling
    down) is deliberately NOT here: retrying the throttled model wastes the backoff window, so the
    loop falls back to another model immediately (is_rate_limited handles it)."""
    if is_rate_limited(res):
        return False
    if res.get("kind") == "transport":
        return True
    if res.get("kind") == "http":
        status = res.get("status")
        if status in (408, 409, 500, 502, 503, 504, 529):
            return True
        msg = str(res.get("message") or "").lower()
        if "out of extra usage" in msg:
            return False
        if "overloaded" in msg:
            return True
        if "unknown provider for model" in msg:
            return True
    return False


def send_with_retry(send, body: dict, emit, sleep=time.sleep) -> dict:
    attempt = 0
    while True:
        attempt += 1
        res = send(body)
        if res.get("ok"):
            return res
        if attempt >= RETRY_MAX_ATTEMPTS or not is_transient(res):
            return res
        delay = min(RETRY_MAX_DELAY, RETRY_BASE_DELAY * 2 ** (attempt - 1))
        emit("status", f"transient error ({res.get('kind')}) - retrying in {delay:.1f}s")
        sleep(delay)


# ---- message helpers --------------------------------------------------------


def fix_luau_empty_objects(tools: list) -> list:
    """Luau's JSONEncode emits [] for an EMPTY table, but Anthropic requires input_schema (and its
    `properties`) to be JSON OBJECTS — a no-arg tool crosses the bridge as "properties": [].
    Mirror of the sentinel fix in Anthropic.luau, applied on the Python side of the bridge."""

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "properties" and value == []:
                    node[key] = {}
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    for tool in tools:
        if isinstance(tool, dict):
            if tool.get("input_schema") == []:
                tool["input_schema"] = {"type": "object", "properties": {}}
            walk(tool.get("input_schema"))
    return tools


def with_preamble(instructions: str, messages: list) -> list:
    if not instructions:
        return messages
    return [
        {"role": "user", "content": [{"type": "text", "text": PREAMBLE_HEADER + instructions}]},
        {"role": "assistant", "content": [{"type": "text", "text": PREAMBLE_ACK}]},
    ] + messages


def prune_images_keeping_last(messages: list, keep: int):
    """Replace all but the last `keep` image blocks with a text placeholder, in place.
    Mirrors Compactor.pruneImagesKeepingLast: references + captures both count."""
    slots = []
    for msg in messages:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for i, block in enumerate(content):
            if isinstance(block, dict) and block.get("type") == "image":
                slots.append((content, i))
            elif isinstance(block, dict) and block.get("type") == "tool_result":
                inner = block.get("content")
                if isinstance(inner, list):
                    for j, ib in enumerate(inner):
                        if isinstance(ib, dict) and ib.get("type") == "image":
                            slots.append((inner, j))
    for container, index in slots[: max(0, len(slots) - keep)]:
        container[index] = {
            "type": "text",
            "text": "[an earlier image was pruned to keep context small]",
        }


TRIM_PLACEHOLDER = "[trimmed: earlier tool output removed after context overflow]"


def _trim_pass(msgs: list, tool_results_only: bool) -> int:
    changed = 0
    for msg in msgs:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_result":
                if block.get("content") != TRIM_PLACEHOLDER:
                    block["content"] = TRIM_PLACEHOLDER
                    changed += 1
            elif (
                not tool_results_only
                and block.get("type") == "text"
                and len(str(block.get("text") or "")) > 2000
            ):
                block["text"] = str(block["text"])[:2000] + " …[trimmed after context overflow]"
                changed += 1
    return changed


def emergency_trim(messages: list, keep_tail: int = 8) -> int:
    """Context-overflow fallback (no summarize call): blank tool_result payloads and truncate
    long text outside the last keep_tail messages. If that changes nothing (short history whose
    NEWEST tool_result is itself the overflow), blank tool_results everywhere — a placeholder
    the model can react to beats killing the run. Returns blocks changed."""
    keep_tail = min(keep_tail, max(0, len(messages) - 2))
    changed = _trim_pass(messages[: len(messages) - keep_tail], tool_results_only=False)
    if changed == 0:
        changed = _trim_pass(messages, tool_results_only=True)
    return changed


def _tool_result_block(tool_use_id: str, bridge_result) -> dict:
    """Build the tool_result block from a raw-mode bridge result (or a timeout)."""
    if bridge_result is None or bridge_result.get("_timeout"):
        if bridge_result is not None and bridge_result.get("dispatched") is False:
            text = (
                "bridge timeout — Studio never picked the tool up (dev bridge not polling?). "
                "The tool did NOT run; it is safe to retry once."
            )
        else:
            text = (
                "bridge timeout — Studio claimed the tool but returned no result in time. "
                "It may STILL be running: do NOT blindly retry a destructive tool; verify "
                "the world state first (get_tree/get_properties)."
            )
        return {
            "type": "tool_result",
            "tool_use_id": tool_use_id,
            "content": text,
            "is_error": True,
        }
    content = bridge_result.get("content")
    banner = str(bridge_result.get("banner") or "")
    if isinstance(content, list) and content:
        blocks = list(content)
        if banner:
            blocks.insert(0, {"type": "text", "text": banner})
        out_content = blocks
    else:
        if isinstance(content, list):  # Luau {} JSON-encodes to [] — treat as empty text
            content = ""
        out_content = banner + str(content if content is not None else "")
        if out_content == "":
            out_content = "(no output)"
    block = {"type": "tool_result", "tool_use_id": tool_use_id, "content": out_content}
    if bridge_result.get("isError") or bridge_result.get("ok") is False:
        block["is_error"] = True
    return block


# ---- the runner -------------------------------------------------------------


class LoopRunner:
    """One loop at a time. start() spawns a daemon thread; status() is safe from any thread."""

    def __init__(self, bridge: BridgeCaller, send_factory=None, loops_dir: str = LOOPS_DIR, sleep=time.sleep):
        self._bridge = bridge
        self._send_factory = send_factory or (
            lambda desc: ModelClient(desc["baseUrl"], desc["proxyKey"]).send
        )
        self._loops_dir = loops_dir
        self._sleep = sleep
        self._lock = threading.Lock()
        self._counter = 0
        self._status = {"state": "idle"}

    def status(self) -> dict:
        with self._lock:
            return json.loads(json.dumps(self._status))  # deep copy — no shared mutable state

    def _set(self, **kv):
        with self._lock:
            self._status.update(kv)

    def start(self, prompt: str, max_iterations=None, model=None) -> int:
        if not isinstance(prompt, str) or not prompt.strip():
            raise LoopError("prompt is required")
        # Validate BEFORE committing state="running" — a bad value must fail this request,
        # not throw inside the daemon thread (which would wedge the runner).
        if max_iterations is not None:
            try:
                max_iterations = int(max_iterations)
            except (TypeError, ValueError):
                raise LoopError("maxIterations must be a number") from None
            if max_iterations < 1:
                raise LoopError("maxIterations must be >= 1")
        if model is not None and not isinstance(model, str):
            raise LoopError("model must be a string")
        with self._lock:
            if self._status.get("state") == "running":
                raise LoopError("a loop is already running — one at a time (single-slot bridge)")
            self._counter += 1
            run_id = self._counter
            self._status = {
                "state": "running",
                "id": run_id,
                "prompt": prompt[:200],
                "iteration": 0,
                "toolCalls": 0,
                "startedAt": time.time(),
                "recent": [],
            }
        thread = threading.Thread(
            target=self._run, args=(run_id, prompt.strip(), max_iterations, model), daemon=True
        )
        thread.start()
        return run_id

    # -- internals --

    def _transcript(self, run_id: int):
        os.makedirs(self._loops_dir, exist_ok=True)
        # Timestamped name: run ids restart at 1 when the sidecar restarts, and two runs
        # appending into one file makes the record unreadable.
        path = os.path.join(self._loops_dir, f"loop-{int(time.time())}-{run_id:04d}.jsonl")

        def write(event: str, data):
            try:
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"t": time.time(), "event": event, "data": data}) + "\n")
            except OSError:
                pass

        return write

    def _run(self, run_id: int, prompt: str, max_iterations, model):
        # Total guard: an uncaught throw in the body must NEVER leave state="running"
        # (that wedges every future /loop behind a 409 until a sidecar restart).
        try:
            self._run_inner(run_id, prompt, max_iterations, model)
        except Exception as exc:  # noqa: BLE001
            self._set(state="error", error=f"internal loop error: {exc!r}")

    def _run_inner(self, run_id: int, prompt: str, max_iterations, model):
        write = self._transcript(run_id)

        def emit(event: str, data):
            write(event, data)
            with self._lock:
                # Monotonic event counter — the ps1 poller diffs on this (the recent list
                # is a rotating 6-cap, so its Count alone goes silent once full).
                self._status["events"] = int(self._status.get("events") or 0) + 1
                if event in ("status", "assistant_text"):
                    recent = self._status.setdefault("recent", [])
                    recent.append(str(data)[:300])
                    del recent[:-6]

        def fail(message: str):
            emit("error", message)
            self._set(state="error", error=message)

        emit("start", {"prompt": prompt})
        describe = self._bridge.call({"kind": "describe"}, DESCRIBE_TIMEOUT)
        if describe is None or describe.get("_timeout"):
            return fail(
                "the plugin bridge did not answer `describe` — is Studio open with the dev "
                "bridge active (and no other client driving /agent)?"
            )
        if not describe.get("ok"):
            return fail("describe failed: " + str(describe.get("error")))
        tools = fix_luau_empty_objects(describe.get("tools") or [])
        instructions = str(describe.get("instructions") or "")
        images_kept = int(describe.get("imagesKept") or 6)
        max_iter = int(max_iterations or describe.get("maxIterations") or 40)
        send = self._send_factory(describe)
        deadline = time.monotonic() + WALL_CLOCK_CAP

        # The active model persists across iterations: once the primary rate-limits and we fall
        # back, STAY on the fallback for the rest of the run (don't re-trigger the primary's 429).
        active_model = model or describe.get("model")
        fallbacks = [m for m in MODEL_FALLBACKS if m != active_model]
        messages = [{"role": "user", "content": [{"type": "text", "text": prompt}]}]
        final_text = ""
        trimmed_once = False
        for i in range(1, max_iter + 1):
            if time.monotonic() > deadline:
                return fail(f"wall-clock cap hit after {i - 1} iterations")
            self._set(iteration=i, model=active_model)
            prune_images_keeping_last(messages, images_kept)

            # Send, with a ONE-SHOT emergency trim if the prompt outgrew the context window
            # (the deterministic stand-in for Luau's compact-and-retry).
            while True:
                body = {
                    "model": active_model,
                    "max_tokens": int(describe.get("maxTokens") or 8192),
                    "messages": with_preamble(instructions, messages),
                    "tools": tools,
                }
                res = send_with_retry(send, body, emit, self._sleep)
                if res.get("ok"):
                    break
                if is_context_length_error(res) and not trimmed_once:
                    trimmed_once = True
                    changed = emergency_trim(messages)
                    emit("status", f"context overflow — trimmed {changed} old blocks, retrying")
                    if changed > 0:
                        continue
                if is_rate_limited(res) and fallbacks:
                    active_model = fallbacks.pop(0)
                    emit("status", f"{res.get('status')} rate-limited - falling back to {active_model}")
                    continue
                return fail(f"model error [{res.get('kind')}]: {res.get('message')}")
            data = res.get("data") or {}
            content = data.get("content")
            stop_reason = data.get("stop_reason")
            if not isinstance(content, list):
                return fail("response had no content array")
            if not content:
                # 0 output blocks (cap hit before anything emitted): a CLEAN terminal stop —
                # never append an empty assistant turn (API-invalid) and never call it an error.
                emit("done", {"iterations": i, "stop": str(stop_reason)})
                self._set(state="done", result=final_text)
                return

            tool_uses = []
            turn_text = []
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    turn_text.append(str(block.get("text") or ""))
                elif block.get("type") == "tool_use":
                    tool_uses.append(block)
                # server_tool_use (web_search/web_fetch) runs Anthropic-side: never dispatched.
            if turn_text:
                emit("assistant_text", "\n".join(turn_text))
                final_text = "\n".join(turn_text)

            messages.append({"role": "assistant", "content": content})
            if not tool_uses:
                if stop_reason == "pause_turn":
                    # A server tool (web_search/web_fetch) paused the turn: echo the assistant
                    # content (already appended) and re-send to resume — parity with Luau.
                    emit("status", "server tool paused the turn — resuming")
                    continue
                if stop_reason == "max_tokens":
                    # The output cap cut the turn mid-write: nudge a continuation instead of
                    # reporting a silently truncated result as success — parity with Luau.
                    emit("status", "output hit the token cap — asking for the continuation")
                    messages.append({
                        "role": "user",
                        "content": [{
                            "type": "text",
                            "text": "(your output hit the token cap — continue EXACTLY where "
                            "it cut off, without repeating what you already produced)",
                        }],
                    })
                    continue
                emit("done", {"iterations": i})
                self._set(state="done", result=final_text)
                return

            results = []
            for tu in tool_uses:
                if time.monotonic() > deadline:
                    return fail(f"wall-clock cap hit during iteration {i}")
                name = str(tu.get("name"))
                emit("tool_use", {"name": name, "input": tu.get("input")})
                bridge_result = self._bridge.call(
                    {"kind": "tool", "tool": name, "input": tu.get("input") or {}, "raw": True},
                    TOOL_TIMEOUT,
                )
                with self._lock:
                    self._status["toolCalls"] = int(self._status.get("toolCalls") or 0) + 1
                results.append(_tool_result_block(str(tu.get("id")), bridge_result))
            messages.append({"role": "user", "content": results})

        emit("done", {"iterations": max_iter, "capped": True})
        self._set(
            state="done",
            result=final_text
            + "\n(iteration cap reached — the work so far is applied; run again to continue)",
        )
