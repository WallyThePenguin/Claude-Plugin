# One-time interactive Claude SUBSCRIPTION login.
# Prints an Anthropic OAuth URL; approve it in a browser ON THIS MACHINE (the callback
# returns to localhost:54545). The token persists in the cliproxy-auth volume, shared
# with the running proxy. Flags match Project Hecate's verified invocation (single-dash).
$ErrorActionPreference = "Stop"

if (-not (Test-Path (Join-Path $PSScriptRoot "config.yaml"))) {
	throw "config.yaml not found - run .\gen-key.ps1 first."
}

docker volume create cliproxy-auth | Out-Null

docker run --rm -it `
	-p 127.0.0.1:54545:54545 `
	-v "${PSScriptRoot}\config.yaml:/CLIProxyAPI/config.yaml:ro" `
	-v cliproxy-auth:/data/cli-proxy-api `
	eceasy/cli-proxy-api@sha256:f204cbf810cf1140bb8cf1fd114ad05306bd78b564a3388891b12a3f18f4afe3 `
	./CLIProxyAPI -config /CLIProxyAPI/config.yaml -claude-login -no-browser -oauth-callback-port 54545
