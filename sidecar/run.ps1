# Start the Studio Agent vision sidecar. Leave this window open while using the capture tool.
# First run: install deps once ->  py -m pip install -r requirements.txt
$ErrorActionPreference = "Stop"

# Token: reuse one persisted next to this script, or generate + save a fresh one (so it survives
# restarts and matches what you paste into the plugin's sidecar settings).
$tokenFile = Join-Path $PSScriptRoot ".token"
if (Test-Path $tokenFile) {
	$token = (Get-Content $tokenFile -Raw).Trim()
} else {
	$bytes = New-Object byte[] 24
	$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
	try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
	$token = -join ($bytes | ForEach-Object { $_.ToString("x2") })
	Set-Content -Path $tokenFile -Value $token -Encoding ascii -NoNewline
}

Write-Host "Sidecar token (paste into the plugin's 'Sidecar token' setting):" -ForegroundColor Cyan
Write-Host $token
Write-Host ""

$env:SIDECAR_TOKEN = $token
$env:SIDECAR_PORT = "8389"
py "$PSScriptRoot\server.py"
