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


def mock_transport_full(responses):
    """Like mock_transport, but the call log also captures method + posted body
    [{"url", "timeout", "method", "data"}...] for the luau POST surface."""
    calls = []

    def fake_urlopen(req, timeout=None):
        calls.append({
            "url": req.full_url, "timeout": timeout,
            "method": req.get_method(), "data": req.data,
        })
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

        # --- luau execution session tasks (bodies below are the LIVE-observed 2026-07-11
        #     shapes, trimmed): create POST / get task / get logs, fail-open without key ---
        TASK_PATH = (
            "universes/20200327/places/20577655/versions/1/luau-execution-sessions/"
            "e14320fd-b09a-49be-bc53-bc7c82745d58/tasks/e14320fd-b09a-49be-bc53-bc7c82745d58"
        )
        opencloud._log = lambda msg: None

        # no key: all three fail open, zero transport calls
        use_missing_key(root)
        calls = mock_transport_full([])
        no_key = (
            opencloud.create_luau_task(20200327, 20577655, "return 1+1"),
            opencloud.get_luau_task(TASK_PATH),
            opencloud.get_luau_task_logs(TASK_PATH),
        )
        fails += _check(
            "luau: no key -> ok=False + reason on all three, zero transport calls",
            all(r["ok"] is False and "no Open Cloud key" in r["reason"] for r in no_key)
            and calls == [],
        )

        use_key_file(root, FAKE_KEY)
        # create happy path: POST shape + task object back
        create_body = json.dumps({
            "path": TASK_PATH, "createTime": "2026-07-11T04:54:56.032Z",
            "updateTime": "2026-07-11T04:54:56.032Z", "user": "6032068",
            "state": "PROCESSING", "script": "return 1+1", "enableBinaryOutput": False,
        })
        calls = mock_transport_full([FakeResp(200, create_body)])
        res = opencloud.create_luau_task("20200327", 20577655, "return 1+1")
        fails += _check(
            "luau create: 200 -> ok + task data (path, state PROCESSING)",
            res["ok"] and res["status"] == 200
            and res["data"]["path"] == TASK_PATH and res["data"]["state"] == "PROCESSING",
        )
        fails += _check(
            "luau create: POST to the place tasks URL with {'script': ...} JSON body",
            calls == [{
                "url": "https://apis.roblox.com/cloud/v2/universes/20200327"
                       "/places/20577655/luau-execution-session-tasks",
                "timeout": 15, "method": "POST",
                "data": b'{"script": "return 1+1"}',
            }],
        )

        # create input validation never hits the network
        calls = mock_transport_full([])
        bad = (
            opencloud.create_luau_task("not-a-number", 1, "return 1"),
            opencloud.create_luau_task(1, 2, ""),
            opencloud.create_luau_task(1, 2, None),
        )
        fails += _check(
            "luau create: bad ids/script -> ok=False, zero transport calls",
            all(r["ok"] is False for r in bad) and calls == [],
        )

        # get task happy path: COMPLETE with output.results
        done_body = json.dumps({
            "path": TASK_PATH, "state": "COMPLETE", "user": "6032068",
            "output": {"results": [2]}, "enableBinaryOutput": False,
        })
        calls = mock_transport_full([FakeResp(200, done_body)])
        res = opencloud.get_luau_task(TASK_PATH)
        fails += _check(
            "luau get: 200 COMPLETE -> ok + output.results, GET cloud/v2/{path}",
            res["ok"] and res["data"]["state"] == "COMPLETE"
            and res["data"]["output"]["results"] == [2]
            and calls[0]["url"] == "https://apis.roblox.com/cloud/v2/" + TASK_PATH
            and calls[0]["method"] == "GET",
        )

        # logs happy path: messages list (live shape), GET .../logs
        logs_body = json.dumps({"luauExecutionSessionTaskLogs": [
            {"path": TASK_PATH + "/logs/1", "messages": ["probe done"]},
        ]})
        calls = mock_transport_full([FakeResp(200, logs_body)])
        res = opencloud.get_luau_task_logs(TASK_PATH)
        fails += _check(
            "luau logs: 200 -> ok + messages, GET cloud/v2/{path}/logs",
            res["ok"]
            and res["data"]["luauExecutionSessionTaskLogs"][0]["messages"] == ["probe done"]
            and calls[0]["url"] == "https://apis.roblox.com/cloud/v2/" + TASK_PATH + "/logs",
        )

        # task_path validation: only the create-response shape is accepted, no network
        calls = mock_transport_full([])
        bad_paths = (
            "/universes/1/places/2/luau-execution-session-tasks",  # leading slash
            "universes/1/places/2",  # not a session-task path
            "universes/../assets/v1/assets/1/luau-execution-sessions/x/tasks/y",  # traversal
            "universes/1/luau-execution-sessions/x/tasks/y?view=FLAT",  # query smuggling
            None,
        )
        fails += _check(
            "luau path validation: malformed handles -> ok=False, zero transport calls",
            all(
                opencloud.get_luau_task(p)["ok"] is False
                and opencloud.get_luau_task_logs(p)["ok"] is False
                for p in bad_paths
            ) and calls == [],
        )

        # error taxonomy: 403 scope hint, 404 published hint, 200 non-JSON, transport error
        mock_transport_full([http_error(403, '{"code":"PERMISSION_DENIED"}')])
        res = opencloud.create_luau_task(1, 2, "return 1")
        fails += _check(
            "luau 403 -> ok=False + luau-execution-session scope hint + raw kept",
            res["ok"] is False and "luau-execution-session scope" in res["reason"]
            and "PERMISSION_DENIED" in res["raw"],
        )
        mock_transport_full([http_error(404, '{"errors":[{"code":0,"message":""}]}')])
        res = opencloud.get_luau_task(TASK_PATH)
        fails += _check(
            "luau 404 -> ok=False + is-the-place-published hint",
            res["ok"] is False and "published" in res["reason"],
        )
        mock_transport_full([FakeResp(200, "<html>not json</html>")])
        fails += _check(
            "luau 200 non-JSON -> ok=False",
            opencloud.get_luau_task(TASK_PATH)["ok"] is False,
        )
        mock_transport_full([urllib.error.URLError("timed out")])
        res = opencloud.create_luau_task(1, 2, "return 1")
        fails += _check(
            "luau transport error -> ok=False (no raise)",
            res["ok"] is False and "transport error" in res["reason"],
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
        for luau_canned, call in (
            ([FakeResp(200, '{"path":"x","state":"PROCESSING"}')],
             lambda: opencloud.create_luau_task(1, 2, "return 1")),
            ([http_error(403, "denied")], lambda: opencloud.get_luau_task(TASK_PATH)),
            ([urllib.error.URLError("boom")], lambda: opencloud.get_luau_task_logs(TASK_PATH)),
        ):
            calls = mock_transport_full(luau_canned)
            surfaces.append(json.dumps(call()))
            surfaces.extend(c["url"] + repr(c["data"]) for c in calls)
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
