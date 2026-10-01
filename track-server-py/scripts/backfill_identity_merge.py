#!/usr/bin/env python3
"""一次性回填：把历史「匿名 user + 登录 user」合并。

用法（在已配置 DATABASE_URL 的环境）：
  cd track/track-server-py
  python scripts/backfill_identity_merge.py
"""
from __future__ import annotations

import asyncio
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import asyncpg

from app.services.sync import merge_anonymous_into_distinct


async def main() -> None:
    # Prefer env; else load /opt/track/server/.env style KEY=VAL
    dsn = os.environ.get("DATABASE_URL") or os.environ.get("TRACK_DATABASE_URL")
    if not dsn:
        for env_path in (ROOT / ".env", Path("/opt/track/server/.env")):
            if not env_path.is_file():
                continue
            for line in env_path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k.strip() in ("DATABASE_URL", "TRACK_DATABASE_URL"):
                    dsn = v.strip().strip("'").strip('"')
                    break
            if dsn:
                break
    if not dsn:
        dsn = "postgresql://track:track@127.0.0.1:5434/track"
    # asyncpg 要 postgresql://，兼容 postgres://
    if dsn.startswith("postgres://"):
        dsn = "postgresql://" + dsn[len("postgres://") :]
    print(f"connecting {dsn.split('@')[-1]} ...")
    conn = await asyncpg.connect(dsn)
    try:
        pairs = await conn.fetch(
            """
            SELECT DISTINCT e.distinct_id, e.anonymous_id
            FROM events e
            WHERE NULLIF(e.distinct_id, '') IS NOT NULL
              AND NULLIF(e.anonymous_id, '') IS NOT NULL
              AND e.anonymous_id NOT IN ('unknown')
              AND e.distinct_id <> e.anonymous_id
              AND EXISTS (
                  SELECT 1 FROM users u WHERE u.user_id = e.anonymous_id
              )
            """
        )
        print(f"pairs to merge: {len(pairs)}")
        now = datetime.now(timezone.utc)
        for i, row in enumerate(pairs, 1):
            d, a = row["distinct_id"], row["anonymous_id"]
            async with conn.transaction():
                await merge_anonymous_into_distinct(conn, d, a, now)
            if i % 50 == 0 or i == len(pairs):
                print(f"  merged {i}/{len(pairs)}")
        # 补全：登录用户尚无 anonymous_id 时，从最近事件回写
        updated = await conn.execute(
            """
            UPDATE users u SET
                anonymous_id = sub.anonymous_id,
                updated_at = NOW()
            FROM (
                SELECT DISTINCT ON (distinct_id) distinct_id, anonymous_id
                FROM events
                WHERE NULLIF(distinct_id, '') IS NOT NULL
                  AND NULLIF(anonymous_id, '') IS NOT NULL
                  AND anonymous_id NOT IN ('unknown')
                ORDER BY distinct_id, event_time DESC
            ) sub
            WHERE u.user_id = sub.distinct_id
              AND u.anonymous_id IN ('', 'unknown')
            """
        )
        print(f"anonymous_id backfill: {updated}")
    finally:
        await conn.close()
    print("done")


if __name__ == "__main__":
    asyncio.run(main())
