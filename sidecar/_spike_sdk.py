"""_spike_sdk.py — T0 spike for the SP1 SDK loop swap. Run: python sidecar/_spike_sdk.py
Verifies against the REAL SDK + subscription: (R1) big system prompt survives on Windows,
(R3) max_turns semantics, (R4) sentinel verbatim in result, (R5) mcp__ tool naming works,
image tool round-trip, auth path (keychain vs CLAUDE_CODE_OAUTH_TOKEN), is_error key shape.
Prints PASS/FAIL lines; findings recorded in the FINDINGS block below."""
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
    print("token set:", bool(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")))
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

# FINDINGS 2026-07-10:
# (a) AUTH: keychain-without-token FAILED. No CLAUDE_CODE_OAUTH_TOKEN, no ANTHROPIC_API_KEY ->
#     SDK returns "401 Invalid authentication credentials". Reproduced 3 ways (SDK w/ inherited env,
#     SDK w/ CLAUDE_CODE_* stripped, and raw `claude -p` standalone) -> all 401. Root cause: the
#     on-disk keychain token (~/.claude/.credentials.json -> claudeAiOauth, subscriptionType "max")
#     is EXPIRED (expiresAt 2026-06-26, run date 2026-07-10) and standalone refresh does NOT succeed;
#     auth on this box is brokered by the Claude Desktop daemon (daemon-auth-status.json status=
#     "auth_required"; env carries CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH=1 but NO token) and that
#     brokered token is NOT propagated to detached/grandchild processes. => A standalone sidecar
#     CANNOT rely on the logged-in CLI keychain here. Task 5 MUST inject CLAUDE_CODE_OAUTH_TOKEN
#     (or ANTHROPIC_API_KEY, or route via the existing proxy) into the SDK child env.
# (b) R1 big system prompt (~30KB): PARTIALLY VERIFIED. The prompt was accepted + serialized by the
#     SDK/CLI on Windows and the request reached the API (failure was an API-level 401, not a spawn/
#     argv/pipe error) -> Windows transport of a 30KB system_prompt is fine (SDK sends it as stdin
#     JSON, not argv, so the Windows argv limit does not apply). Model-level honoring: BLOCKED by (a).
# (c) R3 assistants vs num_turns: UNVERIFIED (blocked by auth). The only AssistantMessage received was
#     the SDK's synthetic "Failed to authenticate…" message; no real model turns ran; the terminal
#     ResultMessage was subtype="success" but is_error=True (the auth-failure envelope), so num_turns
#     is not a meaningful turn count. Ratio could not be calibrated.
# (d) R4 ResultMessage.result verbatim sentinel: UNVERIFIED (blocked by auth). No real assistant text
#     was produced, so the FACTORY_SPIKE_JSON round-trip could not be exercised.
# (e) is_error acceptance: PARTIAL. The tool RETURN SHAPE {"content":[...], "is_error": True} was
#     accepted at @tool definition + create_sdk_mcp_server registration time with no error; a live
#     tool_result round-trip (model invoking broken_tool) was NOT exercised because the model never ran.
# (f) ORPHAN claude processes: NO. Before/after PID diff around a full spike run showed zero new
#     lingering claude.exe; the SDK tears down its CLI subprocess cleanly even on an auth-failed session.
# (g) SDK API DEVIATIONS from the plan listing: NONE. All imports (AssistantMessage, ClaudeAgentOptions,
#     ResultMessage, TextBlock, ToolUseBlock, create_sdk_mcp_server, query, tool) resolved on 0.2.82.
#     tool(name, desc, {}) / create_sdk_mcp_server(name=, version=, tools=[]) / ClaudeAgentOptions(
#     system_prompt=, mcp_servers=, allowed_tools=, disallowed_tools=, permission_mode="bypassPermissions",
#     max_turns=, env=, setting_sources=[]) all constructed with no TypeError/validation error. No
#     signature fixes were needed. The script ran end-to-end (spawned a real session, yielded an
#     AssistantMessage + a ResultMessage).
# (h) BONUS (for Task 5): on a FAILED session the SDK RAISES `Exception("Claude Code returned an error
#     result: <subtype>")` out of the `async for msg in query(...)` loop, and delivery of the terminal
#     ResultMessage relative to that raise is NOT guaranteed (observed both orders across runs). The
#     runner MUST wrap query() iteration in try/except, treat the raised Exception as the terminal error,
#     and NOT assume a ResultMessage arrives on failure. The plan script itself exits non-zero with a
#     traceback on this box purely because of (a) — its logic is otherwise correct and would print all
#     PASS/FAIL lines on an authenticated machine.
