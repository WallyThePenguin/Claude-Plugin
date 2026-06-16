# Local model proxy — CLIProxyAPI (M-pre)

The Studio Agent plugin talks **only** to a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
instance, which authenticates with your **Claude subscription** (OAuth) and re-exposes an
**Anthropic-compatible** `/v1/messages` endpoint on `127.0.0.1:8317`. No pay-per-token API key.

```
Studio plugin ──HTTP──► 127.0.0.1:8317 (CLIProxyAPI) ──HTTPS, subscription OAuth──► Anthropic
```

Image is pinned by digest to **CLIProxyAPI v7.1.39** (`eceasy/cli-proxy-api`), the build Project
Hecate runs in production.

## Prerequisites

- **Docker Desktop running** (`docker version` succeeds).
- A Claude Pro/Max subscription.

## Setup (one time)

Run these from this `proxy/` directory in PowerShell:

```powershell
# 1. Generate the inbound key and write config.yaml (gitignored). Copy the printed key —
#    you'll paste it into the plugin's "Proxy Key" setting (M1).
.\gen-key.ps1

# 2. Log in with your Claude subscription. Prints an Anthropic OAuth URL; open it in a
#    browser ON THIS MACHINE and approve. The callback returns to localhost:54545 and the
#    token is saved into the `cliproxy-auth` Docker volume.
.\login.ps1

# 3. Start the proxy (loopback only).
docker compose up -d
docker compose logs --tail=30        # should show it listening on :8317, no token errors

# 4. Acceptance gate — proves the key gate, the model list, and a live round-trip.
.\verify.ps1
```

`verify.ps1` passes when:
1. unauthenticated `/v1/models` returns **401/403** (or 200 with a warning — model listing may be ungated),
2. authenticated `/v1/models` returns **200** + a non-empty model list,
3. authenticated `POST /v1/messages` (`claude-opus-4-8`, `max_tokens: 256`) returns an **assistant message** — the authoritative proof the default model works end to end.

## Daily use

- Start: `docker compose up -d` (auto-restarts with Docker via `restart: unless-stopped`).
- Stop: `docker compose down`.
- The plugin needs the proxy **running** to talk to Claude.

## The connection contract (what the plugin sends)

```
POST http://127.0.0.1:8317/v1/messages
Authorization: Bearer <inbound key from gen-key.ps1>
anthropic-version: 2023-06-01
content-type: application/json
{ "model": "claude-opus-4-8", "max_tokens": 8192, "system": ..., "tools": [...], "messages": [...] }
```

`max_tokens` is kept lean (8192 default) on purpose: the subscription rolling window *reserves*
`max_tokens` as potential output, so large values 400 with "out of extra usage" (heavier on opus).

## Security

- **Loopback only.** The port maps `127.0.0.1:8317:8317` — never run a bare `8317:8317`.
- The **subscription OAuth token** lives only in the `cliproxy-auth` Docker volume, never in git
  or the image. `config.yaml` (with the inbound key) is **gitignored**; only `config.example.yaml`
  is committed.
- The inbound key is a low-value *local* access key, not the subscription token.

## Troubleshooting

- **401 from the plugin** → wrong/missing inbound key (must match `config.yaml`'s `api-keys`).
- **Empty model list / `invalid_grant`** → subscription token expired; re-run `.\login.ps1`, then `docker compose restart`.
- **Connection refused** → container down (`docker compose ps`) or Docker not running.
- **Login hangs after browser approval** → confirm the in-container callback bound `0.0.0.0:54545`
  (`docker logs`); if it bound `127.0.0.1` internally the published map won't catch the redirect.
  Fallback: run the native CLIProxyAPI binary's `-claude-login` on the host, then mount the token.
- **Container won't start / config error** → check `docker compose logs`; confirm `config.yaml`
  parsed (the `-config /CLIProxyAPI/config.yaml` path) and the `api-keys` entry is your hex key.
