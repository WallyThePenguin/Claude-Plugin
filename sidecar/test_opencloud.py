"""Dependency-free tests for the Open Cloud client. Run: python sidecar/test_opencloud.py
Transport is MOCKED (opencloud._urlopen) — no network, no real key; the key file is a tempdir
fake wired via STUDIO_AGENT_OPENCLOUD_KEY_FILE. The route test binds an ephemeral localhost
port with the real server.Handler and asserts the no-key 503 fail-open."""
import io
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import opencloud

FAKE_KEY = "FAKE-not-a-real-key-0123456789abcdefFAKE"


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


class FakeResp:
    """Stands in for the urlopen 2xx response context manager."""

    def __init__(self, status, body, headers=None):
        self.status = status
        self._body = body.encode("utf-8")
        self.headers = headers or {}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(code, body, headers=None):
    """urlopen raises HTTPError for non-2xx — build the real thing so exc.read()/.headers work."""
    return urllib.error.HTTPError(
        "https://apis.roblox.com/assets/v1/assets/1", code, "err", headers or {}, io.BytesIO(body.encode())
    )


def mock_transport(responses):
    """Patch opencloud._urlopen to pop canned responses (FakeResp or an Exception to raise).
    Returns the call log [{"url", "timeout"}...]."""
    calls = []

    def fake_urlopen(req, timeout=None):
        calls.append({"url": req.full_url, "timeout": timeout})
        item = responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    opencloud._urlopen = fake_urlopen
    return calls


def use_key_file(root, content):
    path = os.path.join(root, "opencloud.key")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.environ[opencloud.KEY_FILE_ENV] = path
    opencloud._reset()
    return path


def use_missing_key(root):
    path = os.path.join(root, "nope", "missing.key")
    os.environ[opencloud.KEY_FILE_ENV] = path
    opencloud._reset()
    return path


def main():
    fails = 0
    env_before = os.environ.get(opencloud.KEY_FILE_ENV)
    with tempfile.TemporaryDirectory() as root:
        # --- key loading: missing file fails open, logs ONCE (cached), never raises ---
        logs = []
        opencloud._log = logs.append
        missing = use_missing_key(root)
        fails += _check("load_key: missing file -> None", opencloud.load_key() is None)
        fails += _check(
            "load_key: one non-secret log line with the path",
            logs == [f"no key file at {missing}"],
        )
        opencloud.load_key()
        fails += _check("load_key: cached — second call does not re-log", len(logs) == 1)
        res = opencloud.get_asset_status(123)
        fails += _check(
            "no key -> Unavailable + reason (fail-open, no raise)",
            res["state"] == "Unavailable" and "no Open Cloud key" in res["reason"],
        )

        logs = []
        opencloud._log = logs.append
        use_key_file(root, "   \n")
        fails += _check("load_key: empty file -> None + logged", opencloud.load_key() is None and len(logs) == 1)

        use_key_file(root, FAKE_KEY + "\n")
        fails += _check("load_key: reads + strips", opencloud.load_key() == FAKE_KEY)

        # --- 200 happy path: state extraction (live-observed body shape) ---
        for want in ("Approved", "Reviewing", "Rejected"):
            calls = mock_transport(
                [FakeResp(200, json.dumps({"moderationResult": {"moderationState": want}}))]
            )
            res = opencloud.get_asset_status(4249137687)
            fails += _check(
                f"200 {want} -> state {want}",
                res == {"assetId": 4249137687, "state": want,
                        "raw": '{"moderationResult": {"moderationState": "%s"}}' % want},
            )
        fails += _check(
            "request shape: assets/v1 + readMask + 15s timeout",
            calls == [{
                "url": "https://apis.roblox.com/assets/v1/assets/4249137687?readMask=moderationResult",
                "timeout": 15,
            }],
        )

        # moderationResult absent on a 200 (old approved assets) -> Unknown, NOT approval
        mock_transport([FakeResp(200, '{"assetId":"123","state":"Active"}')])
        res = opencloud.get_asset_status(123)
        fails += _check(
            "200 without moderationResult -> Unknown + reason",
            res["state"] == "Unknown" and "absent" in res["reason"],
        )
        mock_transport([FakeResp(200, "<html>not json</html>")])
        fails += _check("200 non-JSON body -> Unknown", opencloud.get_asset_status(123)["state"] == "Unknown")

        # --- error taxonomy (401/403/404/429/5xx/transport) ---
        mock_transport([http_error(401, '{"errors":[{"code":0,"message":"Invalid API Key"}]}')])
        res = opencloud.get_asset_status(123)
        fails += _check(
            "401 -> Unavailable (key invalid/insufficient scope)",
            res["state"] == "Unavailable" and "key invalid or insufficient scope" in res["reason"],
        )
        mock_transport([http_error(403, '{"code":"PERMISSION_DENIED"}')])
        fails += _check(
            "403 -> Unavailable (scope)",
            opencloud.get_asset_status(123)["reason"] == "HTTP 403: key invalid or insufficient scope",
        )
        mock_transport([http_error(404, '{"code":"NOT_FOUND","message":"AssetId 123 is not found"}')])
        res = opencloud.get_asset_status(123)
        fails += _check(
            "404 -> NotFound with raw body kept",
            res["state"] == "NotFound" and "NOT_FOUND" in res["raw"],
        )
        mock_transport([http_error(500, "oops")])
        fails += _check(
            "5xx -> Unavailable transient",
            opencloud.get_asset_status(123)["reason"] == "HTTP 500: transient upstream error",
        )
        mock_transport([urllib.error.URLError("timed out")])
        res = opencloud.get_asset_status(123)
        fails += _check(
            "transport error -> Unavailable (no raise)",
            res["state"] == "Unavailable" and "transport error" in res["reason"],
        )

        # 429: honor Retry-After, retry ONCE, then succeed
        sleeps = []
        opencloud._sleep = sleeps.append
        calls = mock_transport([
            http_error(429, "slow down", headers={"Retry-After": "2"}),
            FakeResp(200, '{"moderationResult":{"moderationState":"Approved"}}'),
        ])
        res = opencloud.get_asset_status(123)
        fails += _check(
            "429 then 200 -> Approved after honoring Retry-After: 2",
            res["state"] == "Approved" and sleeps == [2.0] and len(calls) == 2,
        )
        # 429 twice: exactly one retry, then honest Unavailable; absent header -> default wait
        sleeps = []
        opencloud._sleep = sleeps.append
        calls = mock_transport([http_error(429, "slow"), http_error(429, "slow"), FakeResp(200, "{}")])
        res = opencloud.get_asset_status(123)
        fails += _check(
            "429 twice -> Unavailable rate-limited after ONE retry (default 1.0s wait)",
            res["state"] == "Unavailable" and "429" in res["reason"]
            and sleeps == [opencloud.RETRY_AFTER_DEFAULT_S] and len(calls) == 2,
        )
        fails += _check(
            "Retry-After parse: capped + default on garbage",
            opencloud._retry_after_seconds({"Retry-After": "9999"}) == opencloud.RETRY_AFTER_CAP_S
            and opencloud._retry_after_seconds({"Retry-After": "soon"}) == opencloud.RETRY_AFTER_DEFAULT_S
            and opencloud._retry_after_seconds(None) == opencloud.RETRY_AFTER_DEFAULT_S,
        )

        # bad asset id never hits the network
        calls = mock_transport([])
        res = opencloud.get_asset_status("not-a-number")
        fails += _check(
            "non-integer assetId -> Unavailable, zero transport calls",
            res["state"] == "Unavailable" and calls == [],
        )

        # --- REGRESSION: the key value never leaks into logs, results, or exception text ---
        leak_log = []
        opencloud._log = leak_log.append
        use_key_file(root, FAKE_KEY)
        surfaces = []
        for canned in (
            [FakeResp(200, '{"moderationResult":{"moderationState":"Approved"}}')],
            [http_error(401, "Invalid API Key")],
            [http_error(429, "slow"), http_error(429, "slow")],
            [urllib.error.URLError("boom")],
        ):
            calls = mock_transport(canned)
            surfaces.append(json.dumps(opencloud.get_asset_status(1)))
            surfaces.extend(c["url"] for c in calls)
        surfaces.extend(leak_log)
        fails += _check("regression: some surfaces were captured", len(surfaces) >= 8)
        fails += _check(
            "regression: key value absent from ALL logs/results/urls",
            all(FAKE_KEY not in s for s in surfaces),
        )

        # --- route registration: /opencloud/asset-status fails open to 503 without a key ---
        use_missing_key(root)
        opencloud._log = lambda msg: None
        def _no_network(req, timeout=None):
            raise AssertionError("route test must not touch the network")
        opencloud._urlopen = _no_network
        import server  # noqa: PLC0415 — heavyweight import deferred until needed

        srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        port = srv.server_address[1]
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        try:
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/opencloud/asset-status?assetId=123", timeout=10)
                code, body = 200, {}
            except urllib.error.HTTPError as exc:
                code, body = exc.code, json.loads(exc.read().decode())
            fails += _check(
                "route: no key -> HTTP 503 {'state':'Unavailable','reason':...}",
                code == 503 and body.get("state") == "Unavailable" and "reason" in body,
            )
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/opencloud/asset-status?assetId=abc", timeout=10)
                code = 200
            except urllib.error.HTTPError as exc:
                code = exc.code
            fails += _check("route: non-integer assetId -> HTTP 400", code == 400)
        finally:
            srv.shutdown()
            srv.server_close()
            thread.join(timeout=5)

    if env_before is None:
        os.environ.pop(opencloud.KEY_FILE_ENV, None)
    else:
        os.environ[opencloud.KEY_FILE_ENV] = env_before
    opencloud._reset()

    print(("ALL PASS" if fails == 0 else "%d FAILURE(S)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
