"""Open Cloud client — fetch-free asset moderation status for the mesh two-phase commit.

Replaces the engine-side ContentProvider:PreloadAsync readiness gate (real CDN fetches that
once degraded Studio) with a metadata poll: GET the asset's moderationResult by assetId.

KEY HANDLING (absolute rule): the API key lives in a FILE — default
%USERPROFILE%/.studio-agent/opencloud.key, overridden by the env var
STUDIO_AGENT_OPENCLOUD_KEY_FILE. The key VALUE must NEVER appear in logs, exceptions,
returned dicts, or request dumps — reference it only by path/env name. When the file is
absent every consumer fails open to state "Unavailable" (never raises).

DISCOVERY (live probes 2026-07-11, status/body verbatim; key never printed):
  GET https://apis.roblox.com/assets/v1/assets/4249137687?readMask=moderationResult
    -> 200 {"moderationResult":{"moderationState":"Approved"}}
       (a FOREIGN asset, not ours: the assets/v1 GET surface is NOT ownership-gated for
        reads — no 403-not-yours exists on this endpoint with asset:read scope)
  GET https://apis.roblox.com/assets/v1/assets/999999999999999?readMask=moderationResult
    -> 404 {"code": "NOT_FOUND", "message": "AssetId 999999999999999 is not found"}
  GET https://apis.roblox.com/assets/v1/assets/4249137687          (no readMask)
    -> 200 full object: {"path","revisionId","revisionCreateTime","assetId","displayName",
       "description","assetType","creationContext","moderationResult":{"moderationState":
       "Approved"},"state":"Active"}
  GET https://apis.roblox.com/cloud/v2/assets/4249137687 (with or without readMask)
    -> 404 {"errors":[{"code":0,"message":""}]}          (no cloud/v2 asset resource exists)
  (fake key) -> 401 {"errors":[{"code":0,"message":"Invalid API Key"}]}

moderationState per creator-docs: Reviewing | Rejected | Approved. moderationResult may be
ABSENT even on a 200 (old approved assets) — mapped to "Unknown"; callers must treat Unknown
as not-yet-proven, not as approval. Pure standard library.
"""

import json
import os
import time
import urllib.error
import urllib.request

KEY_FILE_ENV = "STUDIO_AGENT_OPENCLOUD_KEY_FILE"
ASSET_URL = "https://apis.roblox.com/assets/v1/assets/{asset_id}?readMask=moderationResult"
TIMEOUT_S = 15
RETRY_AFTER_DEFAULT_S = 1.0
RETRY_AFTER_CAP_S = 10.0

_KNOWN_STATES = ("Approved", "Reviewing", "Rejected")
_RAW_TRIM = 600

_UNSET = object()
_key_cache = _UNSET

# Indirections so tests can mock transport/clock without touching urllib/time globally.
_urlopen = urllib.request.urlopen
_sleep = time.sleep


def _log(msg: str) -> None:
    """Single log seam. NEVER pass the key value or request headers into this."""
    print(f"opencloud: {msg}", flush=True)


def key_path() -> str:
    """Where the key file is expected: env override first, else the default dotfile."""
    override = os.environ.get(KEY_FILE_ENV)
    if override:
        return override
    home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return os.path.join(home, ".studio-agent", "opencloud.key")


def load_key():
    """The API key, read+stripped ONCE and cached; None when the file is absent or empty
    (one non-secret log line). Every consumer fails open to "Unavailable" on None."""
    global _key_cache
    if _key_cache is not _UNSET:
        return _key_cache
    path = key_path()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            key = fh.read().strip()
    except OSError:
        _log(f"no key file at {path}")
        _key_cache = None
        return None
    if not key:
        _log(f"empty key file at {path}")
        _key_cache = None
        return None
    _key_cache = key
    return key


def _reset() -> None:
    """Test hook: drop the cached key so an env-var override takes effect."""
    global _key_cache
    _key_cache = _UNSET


def _http_get(url: str, key: str):
    """GET with the x-api-key header, 15s timeout. Returns (status, body_text, headers) for
    ANY HTTP status (4xx/5xx included — no raise); transport failures (DNS, timeout, refused)
    propagate as exceptions for the caller to classify. Never logs the key or the headers."""
    req = urllib.request.Request(url, headers={"x-api-key": key})
    try:
        with _urlopen(req, timeout=TIMEOUT_S) as resp:
            return resp.status, resp.read().decode("utf-8", "replace"), resp.headers
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read().decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 — body read can fail on a torn connection
            body = ""
        return exc.code, body, exc.headers


def _retry_after_seconds(headers) -> float:
    """Honor Retry-After (seconds form) on a 429, defaulted and capped."""
    raw = None
    if headers is not None:
        try:
            raw = headers.get("Retry-After")
        except Exception:  # noqa: BLE001
            raw = None
    try:
        seconds = float(raw)
    except (TypeError, ValueError):
        return RETRY_AFTER_DEFAULT_S
    return max(0.0, min(seconds, RETRY_AFTER_CAP_S))


def _result(asset_id, state, raw, reason=None):
    out = {"assetId": asset_id, "state": state, "raw": raw}
    if reason is not None:
        out["reason"] = reason
    return out


def _classify(asset_id, status: int, body: str) -> dict:
    """Map an HTTP status + body to the honest state taxonomy (see module docstring for the
    live-observed shapes each branch is based on)."""
    raw = body[:_RAW_TRIM] if isinstance(body, str) else None
    if status == 200:
        try:
            parsed = json.loads(body)
        except ValueError:
            return _result(asset_id, "Unknown", raw, reason="HTTP 200 with a non-JSON body")
        mod = parsed.get("moderationResult") if isinstance(parsed, dict) else None
        state = mod.get("moderationState") if isinstance(mod, dict) else None
        if state in _KNOWN_STATES:
            return _result(asset_id, state, raw)
        # moderationResult absent (observed on old approved assets) or an unrecognized
        # moderationState value: Unknown — NOT approval; the caller decides how to gate.
        return _result(asset_id, "Unknown", raw, reason="moderationResult absent or unrecognized")
    if status in (401, 403):
        return _result(
            asset_id, "Unavailable", raw,
            reason=f"HTTP {status}: key invalid or insufficient scope",
        )
    if status == 404:
        return _result(asset_id, "NotFound", raw)
    if status == 429:
        return _result(
            asset_id, "Unavailable", raw,
            reason="HTTP 429: rate limited (still limited after one Retry-After retry)",
        )
    if 500 <= status <= 599:
        return _result(
            asset_id, "Unavailable", raw, reason=f"HTTP {status}: transient upstream error"
        )
    return _result(asset_id, "Unavailable", raw, reason=f"HTTP {status}: unexpected status")


def get_asset_status(asset_id) -> dict:
    """Moderation state for an asset id ->
    {"assetId": N, "state": "Approved"|"Reviewing"|"Rejected"|"Unknown"|"NotFound"|"Unavailable",
     "raw": <trimmed body or None>, "reason": <present on Unavailable/Unknown>}.
    Never raises; every failure mode collapses to a state the caller can gate on."""
    try:
        asset_id = int(asset_id)
    except (TypeError, ValueError):
        return _result(asset_id, "Unavailable", None, reason="assetId must be an integer")
    key = load_key()
    if key is None:
        return _result(
            asset_id, "Unavailable", None,
            reason=f"no Open Cloud key (expected at {key_path()})",
        )
    url = ASSET_URL.format(asset_id=asset_id)
    status, body, headers = 0, "", None
    for attempt in (1, 2):
        try:
            status, body, headers = _http_get(url, key)
        except Exception as exc:  # noqa: BLE001 — timeout/DNS/refused: honest transient
            return _result(
                asset_id, "Unavailable", None,
                reason=f"transport error: {type(exc).__name__}: {exc}",
            )
        if status == 429 and attempt == 1:
            wait = _retry_after_seconds(headers)
            _log(f"429 rate limited for asset {asset_id}; retrying once in {wait:.1f}s")
            _sleep(wait)
            continue
        break
    return _classify(asset_id, status, body)
