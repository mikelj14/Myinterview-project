"""Tiny Flask web service: HTML status page at / and a health check at /healthz.

Configuration via environment variables:
  MESSAGE      message shown on the page  (default "Hello from Flask!")
  APP_VERSION  version shown on the page  (default "1.0.0")
  HOSTNAME     pod name; Kubernetes sets this to the pod name automatically
"""
import os
import socket

from flask import Flask, render_template_string

MESSAGE = os.environ.get("MESSAGE", "Hello from Flask!")
VERSION = os.environ.get("APP_VERSION", "1.0.0")
POD_NAME = os.environ.get("HOSTNAME") or socket.gethostname()

# Jinja auto-escapes {{ }} values, so the env vars can't inject HTML.
PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{ message }}</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 36rem; margin: 4rem auto; padding: 0 1rem; }
    dt { font-weight: 600; margin-top: 1rem; }
    dd { margin: 0; font-family: monospace; }
  </style>
</head>
<body>
  <h1>{{ message }}</h1>
  <dl>
    <dt>App version</dt><dd>{{ version }}</dd>
    <dt>Served by pod</dt><dd>{{ pod }}</dd>
  </dl>
</body>
</html>
"""

app = Flask(__name__)


@app.get("/")
def index():
    return render_template_string(PAGE, message=MESSAGE, version=VERSION, pod=POD_NAME)


@app.get("/healthz")
def healthz():
    return "ok\n", 200, {"Content-Type": "text/plain"}


if __name__ == "__main__":
    # Local dev only; the container runs gunicorn (see Dockerfile).
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
