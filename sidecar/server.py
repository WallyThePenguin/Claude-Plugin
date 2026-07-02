"""Studio Agent sidecar — localhost-only capture-file server + dev bridge.

GET  /captures?count=N&since=<epoch>[&b64=1]  -> {"images":[...],"returned":N,"shortfall":bool}
GET  /exemplars?category=<cat>[&b64=1]        -> {"exemplars":[...],"returned":N}
POST /agent      {"kind":"tool"|"luau"|"prompt", ...}     -> {"id":N}
GET  /agent/pending                                       -> the queued command (and clears it) or {}
POST /agent/result {"id":N, ...result}                    -> {"ok":true}
GET  /agent/result?id=N                                   -> the result, or {"status":"pending"}
POST /logs        {"lines":[...]}                          -> {"ok":true}
GET  /logs                                                 -> {"lines":[...]}
POST /reload                                              -> {"id":N}  (flags a hot-reload)
GET  /reload/pending                                      -> {"requested":bool,"id":N,"sources":{...}} | {"requested":true,"id":N,"error":str}
POST /reload/result {"id":N,"ok":bool,"error":?}          -> {"ok":true}
GET  /reload/result?id=N                                  -> the reload outcome, or {"status":"pending"}
POST /play {"cmd":...}                                    -> {"id":N}  (a playtest command)
GET  /play/pending                                        -> the queued play command (and clears it) or {}
POST /play/result {"id":N, ...}                           -> {"ok":true}
GET  /play/result?id=N                                    -> the play command result, or {"status":"pending"}
GET  /store/<kind>                                        -> {"items":[{"id","size","mtime"}]}
GET  /store/<kind>/<id>                                   -> the stored JSON body, or 404
POST /store/<kind>/<id>  <json body>                      -> {"ok":true}   (atomic write; git-tracked)
DELETE /store/<kind>/<id>                                 -> {"ok":true,"existed":bool}

Bind is 127.0.0.1 ONLY — the only trust boundary. No auth. Pure standard library.
"""

import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import capture
import exemplars
import store as filestore
from bridge import Store

PORT = int(os.environ.get("SIDECAR_PORT", "8389"))
STORE = Store()
SRC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")


def read_src_sources() -> dict:
    """Read every src/**/*.luau into {relativePosixPath: source}. Used by the hot-reload channel; the
    sidecar must be run from source (not the frozen exe) for src/ to resolve."""
    sources = {}
    for root, _dirs, files in os.walk(SRC_DIR):
        for name in files:
            if name.endswith(".luau"):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, SRC_DIR).replace(os.sep, "/")
                with open(full, "r", encoding="utf-8") as fh:
                    sources[rel] = fh.read()
    return sources


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
        if parsed.path == "/reload/pending":
            r = STORE.take_reload()
            if r is None:
                return self._json(200, {"requested": False})
            try:
                sources = read_src_sources()
            except Exception as exc:  # noqa: BLE001
                return self._json(200, {"requested": True, "id": r["id"], "error": str(exc)})
            return self._json(200, {"requested": True, "id": r["id"], "sources": sources})
        if parsed.path == "/reload/result":
            try:
                rid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            res = STORE.get_reload_result(rid)
            return self._json(200, res if res is not None else {"status": "pending"})
        if parsed.path == "/play/pending":
            return self._json(200, STORE.play_take_pending() or {})
        if parsed.path == "/play/result":
            try:
                cid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            res = STORE.play_get_result(cid)
            return self._json(200, res if res is not None else {"status": "pending"})
        if parsed.path.startswith("/store/"):
            return self._store_get(parsed.path)
        return self._json(404, {"error": "not found"})

    def _store_parts(self, path: str):
        """Split /store/<kind>[/<id>] -> (kind, id|None)."""
        parts = [p for p in path.split("/") if p][1:]  # drop the leading 'store'
        if len(parts) == 1:
            return parts[0], None
        if len(parts) == 2:
            return parts[0], parts[1]
        return None, None

    def _store_get(self, path: str):
        kind, item_id = self._store_parts(path)
        if kind is None:
            return self._json(400, {"error": "use /store/<kind>[/<id>]"})
        try:
            if item_id is None:
                return self._json(200, {"items": filestore.list_items(kind)})
            body = filestore.read_item(kind, item_id)
        except filestore.StoreError as exc:
            return self._json(400, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        if body is None:
            return self._json(404, {"error": "no such item"})
        return self._json(200, body)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/store/"):
            return self._json(404, {"error": "not found"})
        kind, item_id = self._store_parts(parsed.path)
        if kind is None or item_id is None:
            return self._json(400, {"error": "use DELETE /store/<kind>/<id>"})
        try:
            existed = filestore.delete_item(kind, item_id)
        except filestore.StoreError as exc:
            return self._json(400, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        return self._json(200, {"ok": True, "existed": existed})

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
        if parsed.path == "/reload":
            return self._json(200, {"id": STORE.request_reload()})
        if parsed.path == "/reload/result":
            rid = body.get("id")
            if not isinstance(rid, int):
                return self._json(400, {"error": "reload result needs an integer id"})
            STORE.put_reload_result(rid, body)
            return self._json(200, {"ok": True})
        if parsed.path == "/play":
            return self._json(200, {"id": STORE.play_submit(body)})
        if parsed.path == "/play/result":
            cid = body.get("id")
            if not isinstance(cid, int):
                return self._json(400, {"error": "play result needs an integer id"})
            STORE.play_put_result(cid, body)
            return self._json(200, {"ok": True})
        if parsed.path.startswith("/store/"):
            kind, item_id = self._store_parts(parsed.path)
            if kind is None or item_id is None:
                return self._json(400, {"error": "use POST /store/<kind>/<id>"})
            try:
                filestore.write_item(kind, item_id, body)
            except filestore.StoreError as exc:
                return self._json(400, {"error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": str(exc)})
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
