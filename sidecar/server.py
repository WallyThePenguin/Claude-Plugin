"""Studio Agent sidecar — localhost-only capture-file server + dev bridge.

GET  /captures?count=N&since=<epoch>[&b64=1]  -> {"images":[...],"returned":N,"shortfall":bool}
GET  /exemplars?category=<cat>[&b64=1]        -> {"exemplars":[...],"returned":N}
POST /agent      {"kind":"tool"|"luau"|"prompt", ...}     -> {"id":N}
GET  /agent/pending                                       -> the queued command (and clears it) or {}
POST /agent/result {"id":N, ...result}                    -> {"ok":true}
GET  /agent/result?id=N                                   -> the result, or {"status":"pending"}
POST /logs        {"lines":[...]}                          -> {"ok":true}
GET  /logs                                                 -> {"lines":[...]}

Bind is 127.0.0.1 ONLY — the only trust boundary. No auth. Pure standard library.
"""

import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import capture
import exemplars
from bridge import Store

PORT = int(os.environ.get("SIDECAR_PORT", "8389"))
STORE = Store()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, content_type: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send(code, "application/json", json.dumps(obj).encode())

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path == "/captures":
            return self._captures(qs)
        if parsed.path == "/exemplars":
            return self._exemplars(qs)
        if parsed.path == "/agent/pending":
            return self._json(200, STORE.take_pending() or {})
        if parsed.path == "/agent/result":
            try:
                cid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            result = STORE.get_result(cid)
            return self._json(200, result if result is not None else {"status": "pending"})
        if parsed.path == "/logs":
            return self._json(200, {"lines": STORE.get_logs()})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self._read_json()
        if body is None:
            return self._json(400, {"error": "bad json"})

        if parsed.path == "/agent":
            kind = body.get("kind")
            if kind not in ("tool", "luau", "prompt"):
                return self._json(400, {"error": "kind must be tool|luau|prompt"})
            return self._json(200, {"id": STORE.submit(body)})
        if parsed.path == "/agent/result":
            cid = body.get("id")
            if not isinstance(cid, int):
                return self._json(400, {"error": "result needs an integer id"})
            STORE.put_result(cid, body)
            return self._json(200, {"ok": True})
        if parsed.path == "/logs":
            STORE.set_logs(body.get("lines", []))
            return self._json(200, {"ok": True})
        return self._json(404, {"error": "not found"})

    def _exemplars(self, qs):
        category = qs.get("category", [""])[0]
        want_b64 = qs.get("b64", ["0"])[0] in ("1", "true")
        try:
            items = exemplars.exemplars_for(category, want_b64=want_b64)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        return self._json(200, {"exemplars": items, "returned": len(items)})

    def _captures(self, qs):
        try:
            count = int(qs.get("count", ["1"])[0])
            since = float(qs.get("since", ["0"])[0])
        except ValueError:
            return self._json(400, {"error": "bad count/since"})
        try:
            pngs = capture.newest_captures(count, since_ts=since)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        images = [base64.b64encode(p).decode("ascii") for p in pngs]
        self._json(200, {"images": images, "returned": len(images), "shortfall": len(images) < count})

    def log_message(self, *args):  # silence default stderr access logging
        pass


def main():
    print(f"Studio Agent sidecar listening on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
