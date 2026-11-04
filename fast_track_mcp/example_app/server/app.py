#!/usr/bin/env python3
"""Local demo API for example_app (stdlib + SQLite).

  python3 server/app.py
  # → http://127.0.0.1:18765
  # DB: server/demo.db (auto-seeded)

Endpoints:
  GET  /health
  POST /api/login
  POST /api/logout
  GET  /api/me
  POST /api/profile            {"displayName"}
  POST /api/profile/avatar     {"contentType","dataBase64"}
  GET  /api/home/list
  GET  /avatars/<file>
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import db as store

HOST = "127.0.0.1"
PORT = 18765
DB = store.connect()


def _base_url() -> str:
    return f"http://{HOST}:{PORT}"


def _json_bytes(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


class DemoHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{self.log_date_time_string()}] {self.address_string()} {fmt % args}")

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = _json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Demo-Server", "example_app-py")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path) -> None:
        if not path.is_file() or path.parent.resolve() != store.AVATAR_DIR.resolve():
            self._send(404, {"ok": False, "msg": "not found"})
            return
        data = path.read_bytes()
        ctype, _ = mimetypes.guess_type(str(path))
        self.send_response(200)
        self.send_header("Content-Type", ctype or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=60")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or 0)
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        if length > 0:
            raw = self.rfile.read(length)
        elif "chunked" in te:
            chunks: list[bytes] = []
            while True:
                line = self.rfile.readline()
                if not line:
                    break
                size_s = line.strip().split(b";", 1)[0]
                try:
                    size = int(size_s, 16)
                except ValueError:
                    break
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
            raw = b"".join(chunks) or b"{}"
        else:
            raw = b"{}"
        try:
            data = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            return {}
        return data if isinstance(data, dict) else {}

    def _bearer(self) -> str:
        auth = self.headers.get("Authorization", "") or ""
        if auth.lower().startswith("bearer "):
            return auth[7:].strip()
        return auth.strip()

    def _require_user(self) -> dict[str, Any] | None:
        user = store.user_for_token(DB, self._bearer(), base_url=_base_url())
        if user is None:
            self._send(401, {"ok": False, "msg": "unauthorized"})
            return None
        return user

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            s = store.stats(DB)
            self._send(
                200,
                {
                    "ok": True,
                    "service": "example_app-demo-api",
                    "port": PORT,
                    "db": str(store.DB_PATH.name),
                    "stats": s,
                },
            )
            return
        if path.startswith("/avatars/"):
            name = path.rsplit("/", 1)[-1]
            self._send_file(store.AVATAR_DIR / name)
            return
        if path == "/api/me":
            user = self._require_user()
            if user is None:
                return
            self._send(200, {"ok": True, "user": user})
            return
        if path == "/api/home/list":
            time.sleep(0.22)
            token = self._bearer()
            user = store.user_for_token(DB, token, base_url=_base_url())
            items = store.list_feed_items(DB)
            self._send(
                200,
                {
                    "ok": True,
                    "items": items,
                    "authed": user is not None,
                    "user": user,
                    "tokenPreview": (token[:12] + "…") if token else None,
                },
            )
            return
        self._send(404, {"ok": False, "msg": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/login":
            time.sleep(0.18)
            payload = self._read_json()
            email = str(payload.get("email") or "").strip()
            password = str(payload.get("password") or "")
            if not email or not password:
                self._send(400, {"ok": False, "msg": "email and password required"})
                return
            user = store.authenticate(DB, email, password, base_url=_base_url())
            if user is None:
                self._send(401, {"ok": False, "msg": "invalid email or password"})
                return
            token = store.issue_token(DB, user["id"])
            self._send(
                200,
                {
                    "ok": True,
                    "token": token,
                    "user": user["email"],
                    "displayName": user["displayName"],
                    "avatarUrl": user.get("avatarUrl"),
                },
            )
            return
        if path == "/api/logout":
            time.sleep(0.08)
            token = self._bearer()
            payload = self._read_json()
            if not token:
                token = str(payload.get("token") or "").strip()
            revoked = store.revoke_token(DB, token)
            self._send(200, {"ok": True, "revoked": revoked})
            return
        if path == "/api/profile":
            user = self._require_user()
            if user is None:
                return
            payload = self._read_json()
            name = str(payload.get("displayName") or "").strip()
            if not name:
                self._send(400, {"ok": False, "msg": "displayName required"})
                return
            updated = store.update_display_name(
                DB, user["id"], name, base_url=_base_url()
            )
            self._send(200, {"ok": True, "user": updated})
            return
        if path == "/api/profile/avatar":
            user = self._require_user()
            if user is None:
                return
            payload = self._read_json()
            b64 = str(payload.get("dataBase64") or "")
            # Allow data URL prefix.
            if "," in b64 and b64.strip().lower().startswith("data:"):
                b64 = b64.split(",", 1)[1]
            content_type = str(payload.get("contentType") or "image/jpeg").lower()
            try:
                raw = base64.b64decode(b64, validate=False)
            except Exception:
                self._send(400, {"ok": False, "msg": "invalid base64"})
                return
            if not raw:
                self._send(400, {"ok": False, "msg": "empty image"})
                return
            if len(raw) > 2 * 1024 * 1024:
                self._send(400, {"ok": False, "msg": "image too large (max 2MB)"})
                return
            ext = "jpg"
            if "png" in content_type:
                ext = "png"
            elif "webp" in content_type:
                ext = "webp"
            elif "gif" in content_type:
                ext = "gif"
            updated = store.save_avatar(
                DB, user["id"], raw=raw, ext=ext, base_url=_base_url()
            )
            self._send(200, {"ok": True, "user": updated})
            return
        self._send(404, {"ok": False, "msg": "not found"})

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()


def main() -> None:
    parser = argparse.ArgumentParser(description="example_app demo API")
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument(
        "--reseed",
        action="store_true",
        help="wipe and re-insert mock users / feed items",
    )
    args = parser.parse_args()

    globals()["HOST"] = args.host
    globals()["PORT"] = args.port
    store.init_db(DB, force_reseed=args.reseed)
    s = store.stats(DB)

    server = ThreadingHTTPServer((args.host, args.port), DemoHandler)
    print(f"demo API listening on http://{args.host}:{args.port}")
    print(f"  db={store.DB_PATH} users={s['users']} items={s['items']}")
    print("  mock login: test@test.com / 123456")
    print("  GET  /api/me  POST /api/profile  POST /api/profile/avatar")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")
        server.server_close()
        DB.close()


if __name__ == "__main__":
    main()
