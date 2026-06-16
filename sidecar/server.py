"""Studio Agent vision sidecar — localhost-only, token-authed screenshot server.

GET /screenshot?window=Roblox%20Studio[&b64=1]
  - returns image/png by default, or base64 text when b64=1.
  - requires the token via ?token=<t> or `Authorization: Bearer <t>`.

Bind is 127.0.0.1 ONLY. Combined with the token, this keeps the OS-level capture off the network.
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

        if parsed.path != "/screenshot":
            self._send(404, "application/json", b'{"error":"not found"}')
            return
        if not self._authorized(qs):
            self._send(401, "application/json", b'{"error":"unauthorized"}')
            return

        window = qs.get("window", ["Roblox Studio"])[0]
        try:
            png = capture.capture_window_png(window)
        except Exception as exc:  # noqa: BLE001 - surface any capture failure as JSON
            import json

            self._send(500, "application/json", json.dumps({"error": str(exc)}).encode())
            return

        if qs.get("b64", ["0"])[0] == "1":
            self._send(200, "text/plain", base64.b64encode(png))
        else:
            self._send(200, "image/png", png)

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
