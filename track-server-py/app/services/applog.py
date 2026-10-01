from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from typing import Any

import asyncpg

from app.models import EventRecord, TrackEvent
from app.services.sync import prop_string, resolve_user_id, upsert_user

EVENT_APP_LOG = "app_log"
# 终端日志只保留最近 2 小时，超时自动清理。
APP_LOG_TTL = timedelta(hours=2)


def is_app_log_event(name: str) -> bool:
    return (name or "").strip() == EVENT_APP_LOG


def app_log_cutoff(now: datetime | None = None) -> datetime:
    ts = now or datetime.now(timezone.utc)
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc) - APP_LOG_TTL


async def purge_expired_logs(conn: asyncpg.Connection, now: datetime | None = None) -> int:
    cutoff = app_log_cutoff(now)
    result = await conn.execute(
        "DELETE FROM app_logs WHERE event_time < $1",
        cutoff,
    )
    try:
        return int(result.split()[-1])
    except (ValueError, IndexError):
        return 0


async def ingest_app_log(conn: asyncpg.Connection, e: TrackEvent) -> bool:
    """写入 app_logs；不进 events，不碰 daily_stats。"""
    user_id = resolve_user_id(e)
    ts = e.timestamp or datetime.now(timezone.utc)
    # 过期日志直接丢弃，避免写入立刻被 TTL 扫掉的无用行
    if ts < app_log_cutoff():
        return False

    props = e.properties or {}
    common = e.common_properties or {}

    level = prop_string(props, "level")[:8]
    tag = prop_string(props, "tag")[:128]
    message = prop_string(props, "message")
    source = prop_string(props, "source") or EVENT_APP_LOG

    result = await conn.execute(
        """
        INSERT INTO app_logs (
            event_id, level, tag, message, source,
            properties, common_properties,
            distinct_id, anonymous_id, session_id, user_id, event_time
        ) VALUES (
            $1, $2, $3, $4, $5,
            $6::jsonb, $7::jsonb,
            $8, $9, $10, $11, $12
        )
        ON CONFLICT (event_id) DO NOTHING
        """,
        e.event_id,
        level,
        tag,
        message,
        source[:64],
        json.dumps(props),
        json.dumps(common),
        e.distinct_id,
        e.anonymous_id or "unknown",
        e.session_id or "unknown",
        user_id,
        ts,
    )
    if not result.endswith("1"):
        return False

    # 仅刷新用户最近活跃；不计入 DAU / total_events
    try:
        await upsert_user(conn, e, user_id, ts)
    except Exception:
        pass
    return True


def _row_to_event(row: asyncpg.Record) -> EventRecord:
    props = row["properties"]
    if isinstance(props, str):
        try:
            props = json.loads(props)
        except json.JSONDecodeError:
            props = {}
    if not isinstance(props, dict):
        props = {}
    if row["level"] and "level" not in props:
        props = {**props, "level": row["level"]}
    if row["tag"] and "tag" not in props:
        props = {**props, "tag": row["tag"]}
    if row["message"] and "message" not in props:
        props = {**props, "message": row["message"]}

    common = row["common_properties"]
    if isinstance(common, str):
        try:
            common = json.loads(common)
        except json.JSONDecodeError:
            common = {}
    if not isinstance(common, dict):
        common = {}

    return EventRecord(
        event_id=row["event_id"],
        name=EVENT_APP_LOG,
        properties=props,
        common_properties=common,
        distinct_id=row["distinct_id"],
        anonymous_id=row["anonymous_id"] or "",
        session_id=row["session_id"] or "",
        event_time=row["event_time"],
        received_at=row["received_at"],
    )


def _user_identity_ids(user) -> list[str]:
    ids: list[str] = []
    for v in (user.user_id, user.anonymous_id, user.distinct_id or ""):
        if v and v not in ids:
            ids.append(v)
    return ids


async def list_user_logs(
    pool: asyncpg.Pool,
    user_id: str,
    frm: datetime,
    to: datetime,
    limit: int,
    offset: int,
    order: str = "desc",
    level: str = "",
) -> tuple[list[EventRecord], int] | None:
    from app.services import analytics

    user = await analytics.get_user(pool, user_id)
    if user is None:
        return None
    if limit <= 0:
        limit = 50
    if limit > 1000:
        limit = 1000

    ids = _user_identity_ids(user)
    cutoff = app_log_cutoff()
    # 强制钳制到 TTL 窗口
    if frm < cutoff:
        frm = cutoff
    if to <= frm:
        return [], 0

    order_sql = "DESC" if (order or "").lower() != "asc" else "ASC"
    level_filter = (level or "").strip().lower()
    where = """
        event_time >= $1 AND event_time < $2
          AND (user_id = ANY($3) OR distinct_id = ANY($3) OR anonymous_id = ANY($3))
    """
    args: list[Any] = [frm, to, ids]
    if level_filter:
        where += f" AND lower(level) = ${len(args) + 1}"
        args.append(level_filter)

    async with pool.acquire() as conn:
        try:
            await purge_expired_logs(conn)
        except Exception:
            pass
        total = int(
            await conn.fetchval(f"SELECT COUNT(*) FROM app_logs WHERE {where}", *args) or 0
        )
        limit_idx = len(args) + 1
        offset_idx = len(args) + 2
        rows = await conn.fetch(
            f"""
            SELECT event_id, level, tag, message, source, properties, common_properties,
                   distinct_id, anonymous_id, session_id, user_id, event_time, received_at
            FROM app_logs
            WHERE {where}
            ORDER BY event_time {order_sql}
            LIMIT ${limit_idx} OFFSET ${offset_idx}
            """,
            *args,
            limit,
            offset,
        )
    return [_row_to_event(r) for r in rows], total


async def delete_user_logs(pool: asyncpg.Pool, user_id: str) -> int | None:
    """删除该用户全部终端日志。返回删除行数；用户不存在返回 None。"""
    from app.services import analytics

    user = await analytics.get_user(pool, user_id)
    if user is None:
        return None
    ids = _user_identity_ids(user)
    async with pool.acquire() as conn:
        result = await conn.execute(
            """
            DELETE FROM app_logs
            WHERE user_id = ANY($1) OR distinct_id = ANY($1) OR anonymous_id = ANY($1)
            """,
            ids,
        )
        try:
            return int(result.split()[-1])
        except (ValueError, IndexError):
            return 0
