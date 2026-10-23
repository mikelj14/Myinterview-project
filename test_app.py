"""Run by CI before the image is built: a failing test means nothing gets deployed."""
from app import app

client = app.test_client()


def test_index_shows_message_version_and_pod():
    r = client.get("/")
    assert r.status_code == 200
    assert b"Hello from Flask!" in r.data
    assert b"App version" in r.data
    assert b"Served by pod" in r.data


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.data == b"ok\n"
