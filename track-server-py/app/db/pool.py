from __future__ import annotations

from pathlib import Path
from typing import Optional

import asyncpg

from app.config import settings

_pool = None  # type: Optional[asyncpg.Pool]

MIGRATIONS_DIR = Path(__file__).resolve().parents[2] / "migrations"


async def init_pool():
    global _pool
    _pool = await asyncpg.create_pool(dsn=settings.asyncpg_dsn, min_size=1, max_size=10)
    await migrate(_pool)
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def get_pool():
    if _pool is None:
        raise RuntimeError("database pool not initialized")
    return _pool


async def migrate(pool) -> None:
    files = sorted(MIGRATIONS_DIR.glob("*.sql"))
    async with pool.acquire() as conn:
        for path in files:
            sql = path.read_text(encoding="utf-8")
            await conn.execute(sql)
