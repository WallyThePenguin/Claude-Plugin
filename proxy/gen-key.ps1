# Create config.yaml (gitignored) from the template with a fresh random inbound key.
# Idempotent: refuses to overwrite an existing config.yaml.
$ErrorActionPreference = "Stop"
$example = Join-Path $PSScriptRoot "config.example.yaml"
$config = Join-Path $PSScriptRoot "config.yaml"

if (Test-Path $config) {
	Write-Host "config.yaml already exists - not overwriting. Delete it first to regenerate." -ForegroundColor Yellow
	return
}

# 32 random bytes -> 64 lowercase hex chars (no '|', which CLIProxyAPI disallows in keys).
# Use Create().GetBytes so this works on Windows PowerShell 5.1 (.NET Framework) too —
# the static RandomNumberGenerator.Fill is .NET Core/5+ only.
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
	$rng.GetBytes($bytes)
} finally {
	$rng.Dispose()
}
$key = -join ($bytes | ForEach-Object { $_.ToString("x2") })

(Get-Content $example -Raw).Replace("REPLACE_WITH_HEX_INBOUND_KEY", $key) |
	Set-Content -Path $config -Encoding utf8

Write-Host "Wrote $config" -ForegroundColor Green
Write-Host ""
Write-Host "Inbound key (paste into the plugin's 'Proxy Key' setting):" -ForegroundColor Cyan
Write-Host $key
