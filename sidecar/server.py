"""Studio Agent vision sidecar — localhost-only, token-authed capture-file server.

GET /captures?count=N&since=<epoch>[&max_px=P][&b64=1]
  - reads the N newest complete viewport PNGs Roblox wrote to tmp-capture-storage (mtime >= since).
  - returns JSON {"images":[<base64 png>,...],"returned":N,"shortfall":bool} when b64=1 (the default
    the plugin uses); requires the token via ?token=<t> or `Authorization: Bearer <t>`.

Bind is 127.0.0.1 ONLY. Combined with the token, this keeps disk access off the network.
"""

import base64
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import capture

TOKEN = os.environ.get("SIDECAR_TOKEN", "")
PORT = int(os.environ.get("SIDECAR_PORT", "8389"))


class Handler(BaseHTTPRequestHandler):
    def _authorized(self, qs) -> bool:
        provided = qs.get("token", [""])[0]
        if not provided:
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Bearer "):
                provided = auth[len("Bearer ") :]
        return TOKEN != "" and provided == TOKEN

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
        if not self._authorized(qs):
            self._send(401, "application/json", b'{"error":"unauthorized"}')
            return

        try:
            count = int(qs.get("count", ["1"])[0])
            since = float(qs.get("since", ["0"])[0])
            max_px = int(qs["max_px"][0]) if "max_px" in qs else None
        except ValueError:
            self._send(400, "application/json", b'{"error":"bad count/since/max_px"}')
            return

        import json

        try:
            pngs = capture.newest_captures(count, since_ts=since, max_px=max_px)
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
    if not TOKEN:
        print("SIDECAR_TOKEN is not set — run via run.ps1 (which generates one).", file=sys.stderr)
        sys.exit(1)
    print(f"Studio Agent vision sidecar listening on http://127.0.0.1:{PORT}  (token required)")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
