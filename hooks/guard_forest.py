#!/usr/bin/env python3
"""PreToolUse guard for the Forest CLI's interactive, irreversible commands.

Blocks three commands from being run by the agent:

  forest publish   Irreversible. First publish sets visibility PERMANENTLY (public or
                   private is inherited by every later version and can only be changed
                   by republishing under a new name). It also takes no flags at all and
                   prompts for everything, so it needs a TTY and would hang here.
  forest login     Authentication belongs to the user. Browser or password + 2FA; needs
                   a TTY.
  forest init      The package-authoring scaffold prompts for name and root, so without
                   a TTY it dies with "IO error: not a terminal". `forge.py new` writes
                   the same manifest deterministically.
                   (`forest init --project` IS non-interactive-safe and is allowed.)

Reads the PreToolUse payload on stdin. Exit 0 to allow, exit 2 to block with the reason
on stderr.
"""

from __future__ import annotations

import json
import re
import sys

# `forest` possibly via a wrapper (scripts/forest.sh, forest.ps1, forest.exe),
# then the subcommand. Tolerates flags in between.
GUARDED = {
    "publish": (
        "`forest publish` is irreversible and belongs to the user.\n"
        "First publish sets visibility PERMANENTLY - public or private is inherited by "
        "every later version and can only be changed by republishing under a new name. "
        "It also prompts for everything and needs a TTY, so it would hang here.\n\n"
        "Run the preflight instead (/forest-publish), then hand the user:\n"
        "    forest login\n"
        "    cd packages/<name> && forest publish"
    ),
    "login": (
        "`forest login` is the user's to run - it authenticates through a browser, or a "
        "password with 2FA, and needs a TTY.\n\n"
        "Ask the user to run `forest login` in their own terminal, then continue. "
        "`forest whoami` is allowed and will confirm when they have."
    ),
    "init": (
        "`forest init` (the package-authoring scaffold) prompts for name and root, so "
        "without a TTY it fails with `IO error: not a terminal`.\n\n"
        "Use the deterministic scaffold instead:\n"
        "    python scripts/forge.py new <name> --description \"...\"\n\n"
        "(`forest init --project` is non-interactive-safe and is not blocked.)"
    ),
}

FOREST_CALL = re.compile(
    r"(?:^|[\s;&|(`])(?:[\w./\\-]*\bforest(?:\.exe|\.sh|\.ps1)?)\s+((?:-\S+\s+)*)(\w+)",
    re.IGNORECASE,
)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # Never block on a payload we can't read.

    if payload.get("tool_name") != "Bash":
        return 0

    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str):
        return 0

    for match in FOREST_CALL.finditer(command):
        subcommand = match.group(2).lower()
        reason = GUARDED.get(subcommand)
        if reason is None:
            continue
        # `forest init --project` is explicitly fine: it writes a bare consumer
        # manifest without prompting.
        if subcommand == "init" and "--project" in command:
            continue
        print(f"Blocked: {match.group(0).strip()}\n\n{reason}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
