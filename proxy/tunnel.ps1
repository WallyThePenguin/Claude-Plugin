# Opens the SSH tunnel from this machine to hecate's model proxy (on Otoserver).
# Leave this window OPEN while using the Studio Agent plugin.
#
#   local 127.0.0.1:8318  ->  Otoserver 127.0.0.1:8390 (socat fwd)  ->  hecate llm-proxy:8317
#
# Prereq (one-time, on Otoserver — already done; here for reproducibility):
#   docker run -d --restart unless-stopped --name studio-agent-fwd `
#     --network hecate_hecate_net -p 127.0.0.1:8390:8390 alpine/socat `
#     tcp-listen:8390,fork,reuseaddr tcp-connect:llm-proxy:8317
$ErrorActionPreference = "Stop"
$key = Join-Path $env:USERPROFILE ".ssh\d33kvr3_ed25519"
Write-Host "Tunnel up: 127.0.0.1:8318 -> hecate llm-proxy (Ctrl+C to stop). Leave open while using the plugin."
ssh -i $key -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 `
	-N -L 8318:127.0.0.1:8390 devel@100.119.185.111
