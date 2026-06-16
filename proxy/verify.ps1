# Acceptance gate for the local proxy. Uses curl.exe (NOT the PowerShell `curl` alias).
# Reads the inbound key from config.yaml and exercises the three contract checks.
$ErrorActionPreference = "Stop"
$config = Join-Path $PSScriptRoot "config.yaml"
if (-not (Test-Path $config)) { throw "config.yaml not found - run .\gen-key.ps1 first." }

$m = Select-String -Path $config -Pattern '^\s*-\s*"([0-9a-fA-F]{16,})"' | Select-Object -First 1
if (-not $m) { throw "No inbound key found in config.yaml (still the placeholder? run gen-key.ps1)." }
$key = $m.Matches[0].Groups[1].Value
$base = "http://127.0.0.1:8317"

Write-Host "1) Unauthenticated GET /v1/models (expect 401; 200 = warn: model list ungated)..."
$code = & curl.exe -s -o NUL -w "%{http_code}" "$base/v1/models"
if ($code -eq "401" -or $code -eq "403") { Write-Host "   -> HTTP $code (gated, good)" -ForegroundColor Green }
elseif ($code -eq "200") { Write-Host "   -> HTTP 200 (WARN: model listing is ungated)" -ForegroundColor Yellow }
else { Write-Host "   -> HTTP $code (unexpected)" -ForegroundColor Yellow }

Write-Host "2) Authenticated GET /v1/models (expect 200 + non-empty model list)..."
& curl.exe -s -H "Authorization: Bearer $key" "$base/v1/models"
Write-Host ""

Write-Host "3) Authenticated POST /v1/messages (claude-opus-4-8, max_tokens 256) - THE proof..."
$body = '{"model":"claude-opus-4-8","max_tokens":256,"messages":[{"role":"user","content":"Reply with the single word: ok"}]}'
& curl.exe -s -H "Authorization: Bearer $key" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d $body "$base/v1/messages"
Write-Host ""
Write-Host "If step 3 returned an assistant message with text, the proxy + subscription work." -ForegroundColor Cyan
