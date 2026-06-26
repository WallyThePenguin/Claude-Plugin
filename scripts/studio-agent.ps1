# studio-agent.ps1 — drive the in-Studio plugin from the shell via the localhost sidecar (dev bridge).
# Usage:
#   .\studio-agent.ps1 tool <name> '<json-input>'   e.g. tool spawn_rig '{"type":"r15"}'
#   .\studio-agent.ps1 luau '<luau code>'
#   .\studio-agent.ps1 prompt '<text>'
#   .\studio-agent.ps1 logs
#   .\studio-agent.ps1 reload                          hot-reload the plugin (no Studio restart)
#   .\studio-agent.ps1 capture [outfile.png]
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [string]$Arg1,
    [string]$Arg2
)
$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:8389"

function Submit-And-Wait($payload, $timeoutSec) {
    $body = $payload | ConvertTo-Json -Depth 20 -Compress
    $resp = Invoke-RestMethod -Method Post -Uri "$base/agent" -Body $body -ContentType "application/json"
    $id = $resp.id
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $r = Invoke-RestMethod -Method Get -Uri "$base/agent/result?id=$id"
        if ($r.PSObject.Properties.Name -contains "ok") { return $r }
    }
    return @{ ok = $false; error = "timed out waiting for a result (is Studio open with the bridge active?)" }
}

switch ($Command) {
    "tool" {
        $toolInput = if ($Arg2) { $Arg2 | ConvertFrom-Json } else { @{} }
        $r = Submit-And-Wait @{ kind = "tool"; tool = $Arg1; input = $toolInput } 150
        "ok=$($r.ok)"; $r.result; if ($r.error) { "ERROR: $($r.error)" }
    }
    "luau" {
        $r = Submit-And-Wait @{ kind = "luau"; code = $Arg1 } 30
        "ok=$($r.ok)"; $r.result; if ($r.error) { "ERROR: $($r.error)" }
    }
    "prompt" {
        $r = Submit-And-Wait @{ kind = "prompt"; prompt = $Arg1 } 180
        "ok=$($r.ok)"; "--- reply ---"; $r.reply
        if ($r.tools) { "--- tools ---"; $r.tools | ForEach-Object { "$($_.name) (isError=$($_.isError)): $($_.text)" } }
        if ($r.error) { "ERROR: $($r.error)" }
    }
    "logs" {
        $r = Invoke-RestMethod -Method Get -Uri "$base/logs"
        $r.lines | ForEach-Object { "[$($_.kind)] $($_.text)" }
    }
    "reload" {
        $r = Invoke-RestMethod -Method Post -Uri "$base/reload" -Body "{}" -ContentType "application/json"
        $id = $r.id
        $deadline = (Get-Date).AddSeconds(30)
        $done = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $res = Invoke-RestMethod -Method Get -Uri "$base/reload/result?id=$id"
            if ($res.PSObject.Properties.Name -contains "ok") {
                if ($res.ok) { "reload ok" } else { "reload FAILED: $($res.error)" }
                $done = $true
                break
            }
        }
        if (-not $done) { "reload: timed out waiting for the plugin (is Studio open with the bridge active?)" }
    }
    "capture" {
        $out = if ($Arg1) { $Arg1 } else { Join-Path $env:TEMP "studio-agent-capture.png" }
        $r = Invoke-RestMethod -Method Get -Uri "$base/captures?count=1&b64=1"
        if ($r.returned -lt 1) { "no capture available - have the agent call capture/camera_focus first"; break }
        [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String($r.images[0]))
        "saved $out"
    }
    default { "unknown command: $Command (use tool|luau|prompt|logs|reload|capture)" }
}
