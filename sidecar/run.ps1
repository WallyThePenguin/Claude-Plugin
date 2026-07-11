# Run the Studio Agent sidecar from source (dev convenience). For capture-only use, double-click the
# bundled StudioAgentSidecar.exe instead (no Python needed) — but note the exe does NOT load the env
# file below, so loop/factory/opencloud features need this script (or vars set by hand).
# Leave this window open while the sidecar serves.
#
# Env wiring (reproducible restarts): before launching Python this script loads
#   %USERPROFILE%\.studio-agent\sidecar.env
# (KEY=VALUE lines, full-line # comments, blank lines ignored, %VAR% expanded, optional surrounding
# quotes stripped). Created with a commented template on first run. Precedence: values already set in
# the launching shell WIN over the file (one-off overrides stay easy); blank values in the file are
# skipped. SECURITY: only variable NAMES are ever echoed — never values. Secrets themselves (e.g. the
# Open Cloud key) stay in their own files; the env file carries only paths/settings.
#
# Dry run without starting a second sidecar:  .\run.ps1 -EnvOnly
[CmdletBinding()]
param(
    # Load + report the env file (key NAMES only), then exit WITHOUT starting Python.
    # Safe while a sidecar is already live on the port — no server is started.
    [switch]$EnvOnly
)
$ErrorActionPreference = "Stop"

$envDir = Join-Path $env:USERPROFILE ".studio-agent"
$envFile = Join-Path $envDir "sidecar.env"

if (-not (Test-Path $envFile)) {
    New-Item -ItemType Directory -Force $envDir | Out-Null
    $template = @'
# Studio Agent sidecar environment — loaded by sidecar/run.ps1 before launching Python.
# Format: KEY=VALUE, one per line. Full-line # comments and blank lines are ignored.
# %VAR% patterns in values are expanded at load time. Blank values are skipped (var left unset).
# Values already set in the launching shell take precedence over this file.
#
# SECURITY: this file lives in your user profile, OUTSIDE the repo — never commit it or paste
# secret values elsewhere. run.ps1 echoes only the NAMES of the variables it loads, never values.

# OAuth token for the sidecar's SDK agent loop (/loop, /factory, /forever). Leave blank to run
# capture/bridge-only (those routes will refuse without it).
CLAUDE_CODE_OAUTH_TOKEN=

# Audit every Nth factory rung (factory.py; code default is 5 — ops runs at 2).
STUDIO_AGENT_AUDIT_EVERY=2

# PATH to the Roblox Open Cloud API key file (single-line file holding the secret).
# This variable holds ONLY the path — never put the key value in this file.
STUDIO_AGENT_OPENCLOUD_KEY_FILE=%USERPROFILE%/.studio-agent/opencloud.key

# Mesh upload policy (factory.py): manual (default — save_mesh runs draft-only) or auto.
STUDIO_AGENT_MESH_UPLOAD=manual

# Optional: extra MCP config JSON for the mechanic stage (sdk_loop.py).
# STUDIO_AGENT_MECHANIC_MCP=

# Port the sidecar binds on 127.0.0.1 (server.py; default 8389).
# SIDECAR_PORT=8389
'@
    [IO.File]::WriteAllText($envFile, $template, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "created template env file: $envFile (fill in values as needed)"
}

$loaded = @(); $keptFromShell = @(); $blankSkipped = @(); $badLines = @()
$lineNo = 0
foreach ($raw in [IO.File]::ReadAllLines($envFile)) {
    $lineNo++
    $line = $raw.Trim([char]0xFEFF).Trim()   # tolerate a BOM re-added by editors
    if ($line -eq "" -or $line.StartsWith("#")) { continue }
    $eq = $line.IndexOf("=")
    if ($eq -lt 1) { $badLines += $lineNo; continue }
    $key = $line.Substring(0, $eq).Trim()
    $val = $line.Substring($eq + 1).Trim()
    if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $badLines += $lineNo; continue }
    if ($val.Length -ge 2 -and (($val[0] -eq '"' -and $val[$val.Length - 1] -eq '"') -or ($val[0] -eq "'" -and $val[$val.Length - 1] -eq "'"))) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    if ($val -eq "") { $blankSkipped += $key; continue }
    $existing = [Environment]::GetEnvironmentVariable($key, "Process")
    if ($null -ne $existing -and $existing -ne "") { $keptFromShell += $key; continue }
    $val = [Environment]::ExpandEnvironmentVariables($val)
    [Environment]::SetEnvironmentVariable($key, $val, "Process")
    $loaded += $key
}

# SECURITY: names only — never print values.
Write-Host ("sidecar.env: loaded [{0}]" -f ($loaded -join ", "))
if ($keptFromShell.Count) { Write-Host ("sidecar.env: already set in shell, kept [{0}]" -f ($keptFromShell -join ", ")) }
if ($blankSkipped.Count) { Write-Host ("sidecar.env: blank in file, skipped [{0}]" -f ($blankSkipped -join ", ")) }
if ($badLines.Count) { Write-Host ("sidecar.env: unparseable line(s) ignored at {0}" -f ($badLines -join ", ")) }

if (-not $env:SIDECAR_PORT) { $env:SIDECAR_PORT = "8389" }

if ($EnvOnly) {
    Write-Host "-EnvOnly: env loaded; NOT starting the sidecar."
    exit 0
}

py "$PSScriptRoot\server.py"
