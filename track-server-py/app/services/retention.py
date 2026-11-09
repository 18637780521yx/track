"""埋点 / 报告相关数据保留策略：默认只保留最近 7 天。"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

import asyncpg

from app.config import settings


def retention_ttl() -> timedelta:
    days = max(1, int(settings.retention_days))
    return timedelta(days=days)


def retention_cutoff(now: datetime | None = None) -> datetime:
    ts = now or datetime.now(timezone.utc)
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc) - retention_ttl()


def is_past_retention(ts: datetime | None, now: datetime | None = None) -> bool:
    if ts is None:
        return False
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc) < retention_cutoff(now)


def _count_delete(result: str) -> int:
    try:
        return int(result.split()[-1])
    except (ValueError, IndexError):
        return 0


async def purge_expired(conn: asyncpg.Connection, now: datetime | None = None) -> dict[str, int]:
    """删除超过保留期的埋点、稳定性事件、日聚合与过期用户画像。"""
    cutoff = retention_cutoff(now)
    cutoff_date = cutoff.date()
    out: dict[str, int] = {}

    async with conn.transaction():
        out["events"] = _count_delete(
            await conn.execute(
                "DELETE FROM events WHERE event_time < $1",
                cutoff,
            )
        )
        out["stability_events"] = _count_delete(
            await conn.execute(
                "DELETE FROM stability_events WHERE event_time < $1",
                cutoff,
            )
        )
        # issue 用户关联先清，再删空壳 / 过期 issue（FK）
        out["stability_issue_users"] = _count_delete(
            await conn.execute(
                """
                DELETE FROM stability_issue_users siu
                WHERE NOT EXISTS (
                    SELECT 1 FROM stability_events se
                    WHERE se.fingerprint = siu.fingerprint
                )
                   OR EXISTS (
                    SELECT 1 FROM stability_issues si
                    WHERE si.fingerprint = siu.fingerprint
                      AND si.last_seen_at < $1
                )
                """,
                cutoff,
            )
        )
        out["stability_issues"] = _count_delete(
            await conn.execute(
                """
                DELETE FROM stability_issues si
                WHERE si.last_seen_at < $1
                   OR NOT EXISTS (
                        SELECT 1 FROM stability_events se
                        WHERE se.fingerprint = si.fingerprint
                   )
                """,
                cutoff,
            )
        )
        for table in (
            "daily_stats",
            "daily_active_users",
            "daily_paying_users",
            "daily_install_users",
        ):
            out[table] = _count_delete(
                await conn.execute(
                    f"DELETE FROM {table} WHERE date < $1",
                    cutoff_date,
                )
            )

        stale_users = await conn.fetch(
            """
            SELECT user_id FROM users
            WHERE last_seen_at < $1
              AND NOT EXISTS (
                  SELECT 1 FROM events e
                  WHERE e.distinct_id = users.user_id
                     OR e.anonymous_id = users.user_id
                     OR e.distinct_id = users.anonymous_id
                     OR e.anonymous_id = users.anonymous_id
              )
            """,
            cutoff,
        )
        stale_ids = [r["user_id"] for r in stale_users]
        if stale_ids:
            out["subscriptions"] = _count_delete(
                await conn.execute(
                    "DELETE FROM subscriptions WHERE user_id = ANY($1)",
                    stale_ids,
                )
            )
            for table in (
                "daily_active_users",
                "daily_paying_users",
                "daily_install_users",
            ):
                await conn.execute(
                    f"DELETE FROM {table} WHERE user_id = ANY($1)",
                    stale_ids,
                )
            out["users"] = _count_delete(
                await conn.execute(
                    "DELETE FROM users WHERE user_id = ANY($1)",
                    stale_ids,
                )
            )

    return {k: v for k, v in out.items() if v > 0}


def summarize(counts: dict[str, Any]) -> str:
    if not counts:
        return ""
    return ", ".join(f"{k}={v}" for k, v in counts.items())
