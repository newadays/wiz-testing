"""Tasky-py: a todo list backed by MongoDB. Built for the Wiz Technical Exercise.

MONGODB_URI is the only required configuration and is injected by Kubernetes
from a Secret (requirement: Mongo access configured via an environment variable).
"""
import os
import socket
from datetime import datetime, timezone

from bson import ObjectId
from flask import Flask, jsonify, redirect, render_template, request, url_for
from pymongo import MongoClient

app = Flask(__name__)

MONGODB_URI = os.environ.get("MONGODB_URI", "mongodb://localhost:27017/todo")
APP_VERSION = os.environ.get("APP_VERSION", "dev")


def get_collection():
    """One client per process; pymongo pools connections. Short timeouts keep probes honest."""
    if not hasattr(app, "_client"):
        app._client = MongoClient(MONGODB_URI, serverSelectionTimeoutMS=3000, connectTimeoutMS=3000)
    return app._client.get_default_database().todos


@app.get("/")
def index():
    todos = list(get_collection().find().sort("created_at", -1))
    return render_template("index.html", todos=todos, hostname=socket.gethostname(), version=APP_VERSION)


@app.post("/add")
def add():
    text = request.form.get("text", "").strip()
    if text:
        get_collection().insert_one({"text": text, "done": False, "created_at": datetime.now(timezone.utc)})
    return redirect(url_for("index"))


@app.post("/toggle/<id>")
def toggle(id):
    col = get_collection()
    doc = col.find_one({"_id": ObjectId(id)})
    if doc:
        col.update_one({"_id": doc["_id"]}, {"$set": {"done": not doc.get("done", False)}})
    return redirect(url_for("index"))


@app.post("/delete/<id>")
def delete(id):
    get_collection().delete_one({"_id": ObjectId(id)})
    return redirect(url_for("index"))


# JSON API, handy for the demo and for proving data is in the database
@app.get("/api/todos")
def api_list():
    return jsonify([{"id": str(t["_id"]), "text": t["text"], "done": t.get("done", False)} for t in get_collection().find()])


@app.post("/api/todos")
def api_add():
    text = (request.get_json(silent=True) or {}).get("text", "").strip()
    if not text:
        return jsonify(error="text is required"), 400
    r = get_collection().insert_one({"text": text, "done": False, "created_at": datetime.now(timezone.utc)})
    return jsonify(id=str(r.inserted_id), text=text, done=False), 201


@app.get("/healthz/live")
def live():
    return "ok"


@app.get("/healthz/ready")
def ready():
    try:
        get_collection().database.command("ping")
        return "ready"
    except Exception as exc:  # noqa: BLE001
        return f"mongo unreachable: {exc}", 503


@app.get("/version")
def version():
    return jsonify(version=APP_VERSION, hostname=socket.gethostname())


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
