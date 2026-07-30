#!/usr/bin/env bash
# forest.sh - resolve the Forest CLI and pass everything through.
#
# WHY THIS EXISTS: the installer appends %LOCALAPPDATA%\forest-cli\bin to the USER
# PATH, which only reaches shells started afterwards. Any shell already running -
# including this session's - will not see `forest` until it restarts. Rather than
# have every caller remember that, resolve it here.
#
#   scripts/forest.sh install @scope/pkg
#   scripts/forest.sh audit
set -euo pipefail

if command -v forest >/dev/null 2>&1; then
	exec forest "$@"
fi

candidates=(
	"${LOCALAPPDATA:-$HOME/AppData/Local}/forest-cli/bin/forest.exe"
	"$HOME/AppData/Local/forest-cli/bin/forest.exe"
	"$HOME/.local/bin/forest"
)

for candidate in "${candidates[@]}"; do
	if [[ -x "$candidate" ]]; then
		exec "$candidate" "$@"
	fi
done

cat >&2 <<'EOF'
error: the Forest CLI is not installed, or not where this script looks.

Install it:
  Windows (PowerShell):  irm https://releases.forest.dev/install.ps1 | iex
  macOS / Linux:         curl -fsSL https://releases.forest.dev/install.sh | sh

Then open a new terminal and check:  forest --version
EOF
exit 127
