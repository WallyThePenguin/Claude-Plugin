# Run the Studio Agent vision sidecar from source (dev convenience). For normal use, double-click the
# bundled StudioAgentSidecar.exe instead (no Python needed). Leave this window open while capturing.
$ErrorActionPreference = "Stop"
$env:SIDECAR_PORT = "8389"
py "$PSScriptRoot\server.py"
