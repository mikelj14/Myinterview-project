"""Tiny web service: HTML status page at / and a health check at /healthz.

Standard library only. Configuration via environment variables:
  PORT         port to listen on          (default 8080)
  MESSAGE      message shown on the page  (default "Hello from Python!")
  APP_VERSION  version shown on the page  (default "1.0.0")
  HOSTNAME     pod name; Kubernetes sets this to the pod name automatically
"""
import html
import os
import signal
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
MESSAGE = os.environ.get("MESSAGE", "Hello from Python!")
VERSION = os.environ.get("APP_VERSION", "1.0.0")
POD_NAME = os.environ.get("HOSTNAME") or socket.gethostname()

PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{message}</title>
  <style>
    body {{ font-family: system-ui, sans-serif; max-width: 36rem; margin: 4rem auto; padding: 0 1rem; }}
    dt {{ font-weight: 600; margin-top: 1rem; }}
    dd {{ margin: 0; font-family: ui-monospace, monospace; }}
  </style>
</head>
<body>
  <h1>{message}</h1>
  <dl>
    <dt>App version</dt><dd>{version}</dd>
    <dt>Served by pod</dt><dd>{pod}</dd>
  </dl>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body, content_type="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send(200, PAGE.format(
                message=html.escape(MESSAGE),
                version=html.escape(VERSION),
                pod=html.escape(POD_NAME),
            ))
        elif path == "/healthz":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    # As PID 1 in a container, Python ignores SIGTERM unless handled explicitly.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print(f"Listening on :{PORT} (version {VERSION}, pod {POD_NAME})", flush=True)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
