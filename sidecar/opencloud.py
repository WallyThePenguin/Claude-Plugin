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

LUAU EXECUTION SESSION TASKS (live probes 2026-07-11, statuses/bodies verbatim-trimmed; the
headless "run Luau in the cloud without Studio" surface — docs: creator-docs
cloud-services/http-service.md:173-179 lists the operations; no OpenAPI in the clone):
  POST https://apis.roblox.com/cloud/v2/universes/20200327/places/20577655/luau-execution-session-tasks
       body {"script":"return 1+1"}
    -> 200 in 512ms: {"path":"universes/.../places/.../versions/1/luau-execution-sessions/
       <uuid>/tasks/<uuid>","createTime":...,"user":"6032068","state":"PROCESSING",
       "script":"return 1+1","enableBinaryOutput":false}
       (the response path PINS the place version; session id == task id on this surface)
  GET https://apis.roblox.com/cloud/v2/{task_path}
    -> 200: state PROCESSING -> COMPLETE (~1.2s server-side for return 1+1),
       "output":{"results":[2]} on COMPLETE. States observed: PROCESSING, COMPLETE
       (QUEUED/FAILED documented in creator-docs but not observed live).
  GET https://apis.roblox.com/cloud/v2/{task_path}/logs
    -> 200: {"luauExecutionSessionTaskLogs":[{"path":".../logs/1","messages":[...]}]}
       (print() output lands in messages; empty list when the script printed nothing)
  PREREQUISITE (live-confirmed): needs a PUBLISHED place. Open Cloud v2 has NO universe
  enumeration (GET /cloud/v2/universes -> 404); the PUBLIC games API enumerates without a
  key: GET https://games.roblox.com/v2/users/{userId}/games -> universe id + rootPlace id.
  CAVEAT (live-confirmed): AssetService.CreateAssetAsync / CreateMeshPartAsync ARE functions
  in this context and CreateEditableMesh() returns an Object, but every EditableMesh METHOD
  fails with "EditableMesh is not accessible. Go to the Security Tab in Experience Settings
  to enable this API." until the per-universe Mesh & Image APIs toggle is enabled (user
  action, one-time, Game Settings -> Security).
"""

import json
import os
import time
import urllib.error
import urllib.request

KEY_FILE_ENV = "STUDIO_AGENT_OPENCLOUD_KEY_FILE"
ASSET_URL = "https://apis.roblox.com/assets/v1/assets/{asset_id}?readMask=moderationResult"
LUAU_CREATE_URL = (
    "https://apis.roblox.com/cloud/v2/universes/{universe_id}"
    "/places/{place_id}/luau-execution-session-tasks"
)
LUAU_BASE_URL = "https://apis.roblox.com/cloud/v2/"
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


def _http_request(url: str, key: str, method: str = "GET", body=None):
    """HTTP with the x-api-key header, 15s timeout. `body` (a dict) is JSON-encoded for
    POST. Returns (status, body_text, headers) for ANY HTTP status (4xx/5xx included — no
    raise); transport failures (DNS, timeout, refused) propagate as exceptions for the
    caller to classify. Never logs the key or the headers."""
    headers = {"x-api-key": key}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with _urlopen(req, timeout=TIMEOUT_S) as resp:
            return resp.status, resp.read().decode("utf-8", "replace"), resp.headers
    except urllib.error.HTTPError as exc:
        try:
            body_text = exc.read().decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 — body read can fail on a torn connection
            body_text = ""
        return exc.code, body_text, exc.headers


def _http_get(url: str, key: str):
    """GET wrapper kept for the asset-status path (see _http_request)."""
    return _http_request(url, key)


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


# --- Luau execution session tasks (headless cloud Luau; shapes live-observed 2026-07-11,
#     see module docstring). Uniform result: {"ok": bool, "status": int|None} plus
#     "data" (parsed JSON) when ok, else "reason" (+ "raw" trimmed body when there was one).
#     Fail-open doctrine: never raises; no key / bad input / transport error -> ok=False. ---


def _luau_result(ok, status, data=None, reason=None, raw=None):
    out = {"ok": ok, "status": status}
    if data is not None:
        out["data"] = data
    if reason is not None:
        out["reason"] = reason
    if raw is not None:
        out["raw"] = raw
    return out


def _luau_call(url, method="GET", body=None):
    """Shared key-load + request + classify for the luau-execution surface. No retry loop:
    callers poll the task anyway, so a transient failure surfaces honestly instead."""
    key = load_key()
    if key is None:
        return _luau_result(
            False, None, reason=f"no Open Cloud key (expected at {key_path()})"
        )
    try:
        status, text, _headers = _http_request(url, key, method=method, body=body)
    except Exception as exc:  # noqa: BLE001 — timeout/DNS/refused: honest transient
        return _luau_result(
            False, None, reason=f"transport error: {type(exc).__name__}: {exc}"
        )
    raw = text[:_RAW_TRIM] if text else None
    if status == 200:
        try:
            parsed = json.loads(text)
        except ValueError:
            return _luau_result(False, status, reason="HTTP 200 with a non-JSON body", raw=raw)
        return _luau_result(True, status, data=parsed)
    if status in (401, 403):
        return _luau_result(
            False, status, raw=raw,
            reason=(
                f"HTTP {status}: key invalid or missing the "
                "universe.place.luau-execution-session scope"
            ),
        )
    if status == 404:
        return _luau_result(
            False, status, raw=raw,
            reason="HTTP 404: universe/place/task not found (is the place published?)",
        )
    if status == 429:
        return _luau_result(False, status, reason="HTTP 429: rate limited", raw=raw)
    return _luau_result(False, status, reason=f"HTTP {status}: unexpected status", raw=raw)


def create_luau_task(universe_id, place_id, script) -> dict:
    """POST a Luau execution session task; ok=True data is the task object whose "path"
    (version-pinned) is the handle for get_luau_task/get_luau_task_logs polling."""
    try:
        universe_id = int(universe_id)
        place_id = int(place_id)
    except (TypeError, ValueError):
        return _luau_result(False, None, reason="universeId and placeId must be integers")
    if not isinstance(script, str) or not script.strip():
        return _luau_result(False, None, reason="script must be a non-empty string")
    url = LUAU_CREATE_URL.format(universe_id=universe_id, place_id=place_id)
    res = _luau_call(url, method="POST", body={"script": script})
    # One non-secret log line per create outcome (task path or reason) for the sidecar log.
    if res.get("ok"):
        data = res.get("data")
        path = data.get("path", "<no path>") if isinstance(data, dict) else "<no path>"
        _log(f"luau task created: {path}")
    else:
        _log(f"luau task create failed: {res.get('reason')}")
    return res


def _valid_task_path(task_path) -> bool:
    """The ONLY accepted handle is the create-response "path" — relative, universes-rooted,
    session-task shaped, with no traversal/scheme/query smuggling."""
    return (
        isinstance(task_path, str)
        and task_path.startswith("universes/")
        and "/luau-execution-sessions/" in task_path
        and "/tasks/" in task_path
        and ".." not in task_path
        and "://" not in task_path
        and "?" not in task_path
    )


def get_luau_task(task_path) -> dict:
    """GET the task by its create-response path; ok=True data.state is
    QUEUED|PROCESSING|COMPLETE|FAILED, with data.output.results on COMPLETE."""
    if not _valid_task_path(task_path):
        return _luau_result(
            False, None,
            reason=(
                "task_path must be the create-response path "
                "(universes/.../luau-execution-sessions/.../tasks/...)"
            ),
        )
    return _luau_call(LUAU_BASE_URL + task_path)


def get_luau_task_logs(task_path) -> dict:
    """GET the task's logs; ok=True data.luauExecutionSessionTaskLogs[n].messages carries
    print() output (empty list when the script printed nothing)."""
    if not _valid_task_path(task_path):
        return _luau_result(
            False, None,
            reason=(
                "task_path must be the create-response path "
                "(universes/.../luau-execution-sessions/.../tasks/...)"
            ),
        )
    return _luau_call(LUAU_BASE_URL + task_path + "/logs")
