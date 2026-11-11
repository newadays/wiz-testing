"""Unit tests with an in-memory Mongo (mongomock). python -m pytest"""
import mongomock
import pytest

import app as application


@pytest.fixture
def client(monkeypatch):
    application.app._client = mongomock.MongoClient("mongodb://localhost/todo")
    application.app.testing = True
    yield application.app.test_client()
    del application.app._client


def test_health(client):
    assert client.get("/healthz/live").data == b"ok"
    assert client.get("/healthz/ready").data == b"ready"


def test_crud_roundtrip(client):
    r = client.post("/api/todos", json={"text": "write terraform"})
    assert r.status_code == 201
    tid = r.get_json()["id"]
    assert any(t["id"] == tid for t in client.get("/api/todos").get_json())
    assert client.post(f"/toggle/{tid}").status_code == 302
    assert client.get("/api/todos").get_json()[0]["done"] is True
    assert client.post(f"/delete/{tid}").status_code == 302
    assert client.get("/api/todos").get_json() == []


def test_html_renders(client):
    client.post("/add", data={"text": "hello from the form"})
    html = client.get("/").data.decode()
    assert "hello from the form" in html and "Tasky-py" in html


def test_validation(client):
    assert client.post("/api/todos", json={}).status_code == 400
