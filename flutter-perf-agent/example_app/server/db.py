"""SQLite store + mock seed for example_app demo API."""

from __future__ import annotations

import hashlib
import sqlite3
import time
from pathlib import Path
from typing import Any

DB_PATH = Path(__file__).resolve().parent / "demo.db"
AVATAR_DIR = Path(__file__).resolve().parent / "avatars"

# e2e / demo login defaults (must match LoginPage prefill)
MOCK_USERS = [
    ("test@test.com", "123456", "测试用户"),
    ("admin@demo.com", "admin123", "管理员"),
    ("alice@demo.com", "alice123", "Alice"),
]

MOCK_ITEM_TEMPLATES = [
    ("首页 Banner", "运营位 · 春季活动"),
    ("热门推荐", "根据兴趣排序"),
    ("系统公告", "维护窗口 02:00–04:00"),
    ("新功能速览", "网络请求进报告"),
    ("性能小贴士", "profile + --no-dds"),
]


def _hash_password(password: str) -> str:
    return hashlib.sha256(password.encode("utf-8")).hexdigest()


def connect(db_path: Path | None = None) -> sqlite3.Connection:
    path = db_path or DB_PATH
    AVATAR_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def _ensure_avatar_column(conn: sqlite3.Connection) -> None:
    cols = {r[1] for r in conn.execute("PRAGMA table_info(users)").fetchall()}
    if "avatar_path" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN avatar_path TEXT")
        conn.commit()


def init_db(conn: sqlite3.Connection, *, force_reseed: bool = False) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL UNIQUE,
          password_hash TEXT NOT NULL,
          display_name TEXT NOT NULL,
          avatar_path TEXT,
          created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tokens (
          token TEXT PRIMARY KEY,
          user_id INTEGER NOT NULL,
          created_at REAL NOT NULL,
          FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS feed_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          subtitle TEXT NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL
        );
        """
    )
    conn.commit()
    _ensure_avatar_column(conn)

    user_count = conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"]
    item_count = conn.execute("SELECT COUNT(*) AS c FROM feed_items").fetchone()["c"]

    if force_reseed:
        conn.execute("DELETE FROM tokens")
        conn.execute("DELETE FROM feed_items")
        conn.execute("DELETE FROM users")
        conn.commit()
        for f in AVATAR_DIR.glob("*"):
            if f.is_file():
                f.unlink()
        user_count = 0
        item_count = 0

    if user_count == 0:
        now = time.time()
        conn.executemany(
            "INSERT INTO users(email, password_hash, display_name, created_at) "
            "VALUES (?, ?, ?, ?)",
            [
                (email, _hash_password(password), name, now)
                for email, password, name in MOCK_USERS
            ],
        )
        conn.commit()

    if item_count == 0:
        now = time.time()
        rows: list[tuple[str, str, int, float]] = []
        for i in range(60):
            tpl = MOCK_ITEM_TEMPLATES[i % len(MOCK_ITEM_TEMPLATES)]
            rows.append(
                (
                    f"{tpl[0]} #{i}",
                    f"{tpl[1]} · item {i}",
                    i,
                    now,
                )
            )
        conn.executemany(
            "INSERT INTO feed_items(title, subtitle, sort_order, created_at) "
            "VALUES (?, ?, ?, ?)",
            rows,
        )
        conn.commit()


def _public_user(row: sqlite3.Row, *, base_url: str = "") -> dict[str, Any]:
    avatar_url = None
    path = row["avatar_path"] if "avatar_path" in row.keys() else None
    if path:
        name = Path(str(path)).name
        avatar_url = f"{base_url.rstrip('/')}/avatars/{name}"
    return {
        "id": row["id"],
        "email": row["email"],
        "displayName": row["display_name"],
        "avatarUrl": avatar_url,
    }


def authenticate(
    conn: sqlite3.Connection, email: str, password: str, *, base_url: str = ""
) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT id, email, display_name, avatar_path, password_hash "
        "FROM users WHERE email = ?",
        (email,),
    ).fetchone()
    if row is None:
        return None
    if row["password_hash"] != _hash_password(password):
        return None
    return _public_user(row, base_url=base_url)


def issue_token(conn: sqlite3.Connection, user_id: int) -> str:
    raw = f"{user_id}:{time.time()}:{hashlib.sha256(str(time.time_ns()).encode()).hexdigest()}"
    token = "demo-token-" + hashlib.sha256(raw.encode()).hexdigest()[:20]
    conn.execute(
        "INSERT INTO tokens(token, user_id, created_at) VALUES (?, ?, ?)",
        (token, user_id, time.time()),
    )
    conn.commit()
    return token


def revoke_token(conn: sqlite3.Connection, token: str) -> bool:
    if not token:
        return False
    cur = conn.execute("DELETE FROM tokens WHERE token = ?", (token,))
    conn.commit()
    return cur.rowcount > 0


def user_for_token(
    conn: sqlite3.Connection, token: str, *, base_url: str = ""
) -> dict[str, Any] | None:
    if not token:
        return None
    row = conn.execute(
        """
        SELECT u.id, u.email, u.display_name, u.avatar_path
        FROM tokens t
        JOIN users u ON u.id = t.user_id
        WHERE t.token = ?
        """,
        (token,),
    ).fetchone()
    if row is None:
        return None
    return _public_user(row, base_url=base_url)


def update_display_name(
    conn: sqlite3.Connection, user_id: int, display_name: str, *, base_url: str = ""
) -> dict[str, Any] | None:
    name = display_name.strip()
    if not name:
        return None
    if len(name) > 32:
        name = name[:32]
    conn.execute(
        "UPDATE users SET display_name = ? WHERE id = ?",
        (name, user_id),
    )
    conn.commit()
    row = conn.execute(
        "SELECT id, email, display_name, avatar_path FROM users WHERE id = ?",
        (user_id,),
    ).fetchone()
    return _public_user(row, base_url=base_url) if row else None


def save_avatar(
    conn: sqlite3.Connection,
    user_id: int,
    *,
    raw: bytes,
    ext: str,
    base_url: str = "",
) -> dict[str, Any] | None:
    ext = ext.lower().lstrip(".")
    if ext not in {"jpg", "jpeg", "png", "webp", "gif"}:
        ext = "jpg"
    if ext == "jpeg":
        ext = "jpg"
    AVATAR_DIR.mkdir(parents=True, exist_ok=True)
    # Remove old avatars for this user.
    for old in AVATAR_DIR.glob(f"{user_id}.*"):
        old.unlink(missing_ok=True)
    filename = f"{user_id}.{ext}"
    path = AVATAR_DIR / filename
    path.write_bytes(raw)
    conn.execute(
        "UPDATE users SET avatar_path = ? WHERE id = ?",
        (str(path), user_id),
    )
    conn.commit()
    row = conn.execute(
        "SELECT id, email, display_name, avatar_path FROM users WHERE id = ?",
        (user_id,),
    ).fetchone()
    return _public_user(row, base_url=base_url) if row else None


def list_feed_items(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        "SELECT id, title, subtitle FROM feed_items ORDER BY sort_order ASC, id ASC"
    ).fetchall()
    return [
        {"id": r["id"], "title": r["title"], "subtitle": r["subtitle"]} for r in rows
    ]


def stats(conn: sqlite3.Connection) -> dict[str, int]:
    return {
        "users": conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"],
        "items": conn.execute("SELECT COUNT(*) AS c FROM feed_items").fetchone()["c"],
        "tokens": conn.execute("SELECT COUNT(*) AS c FROM tokens").fetchone()["c"],
    }
