"""Studio Agent vision sidecar — localhost-only capture-file server.

GET /captures?count=N&since=<epoch>[&b64=1]
  - reads the N newest complete viewport PNGs Roblox wrote to tmp-capture-storage (mtime >= since).
  - returns JSON {"images":[<base64 png>,...],"returned":N,"shortfall":bool}.

Bind is 127.0.0.1 ONLY — the only trust boundary. No auth: the served asset is just your own Studio
viewport PNGs, and loopback keeps them off the network. Pure standard library (no third-party deps).
"""

import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import capture

PORT = int(os.environ.get("SIDECAR_PORT", "8389"))


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, content_type: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path != "/captures":
            self._send(404, "application/json", b'{"error":"not found"}')
            return

        try:
            count = int(qs.get("count", ["1"])[0])
            since = float(qs.get("since", ["0"])[0])
        except ValueError:
            self._send(400, "application/json", b'{"error":"bad count/since"}')
            return

        try:
            pngs = capture.newest_captures(count, since_ts=since)
        except Exception as exc:  # noqa: BLE001 - surface any read failure as JSON
            self._send(500, "application/json", json.dumps({"error": str(exc)}).encode())
            return

        images = [base64.b64encode(p).decode("ascii") for p in pngs]
        body = json.dumps(
            {"images": images, "returned": len(images), "shortfall": len(images) < count}
        ).encode()
        self._send(200, "application/json", body)

    def log_message(self, *args):  # silence default stderr access logging
        pass


def main():
    print(f"Studio Agent vision sidecar listening on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
