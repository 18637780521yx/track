from __future__ import annotations

import json
from datetime import datetime
from typing import Any

import asyncpg

from app.models import (
    DailyEventStat,
    EventFilter,
    EventRecord,
    EventTrendPoint,
    FunnelResult,
    FunnelStep,
    NamedCount,
    OverviewStats,
    RetentionResult,
    RetentionRow,
    UserRecord,
)
from app.services.parse import SAFE_JSON_KEY, append_event_filters, inclusive_date_range


def _resolved_user_sql(alias: str) -> str:
    """优先 distinct；匿名事件经 users.anonymous_id 回挂到登录用户。"""
    return f"""COALESCE(
        NULLIF({alias}.distinct_id, ''),
        (
            SELECT u.user_id FROM users u
            WHERE u.anonymous_id = {alias}.anonymous_id
              AND NULLIF(u.distinct_id, '') IS NOT NULL
            ORDER BY u.last_seen_at DESC
            LIMIT 1
        ),
        {alias}.anonymous_id
    )"""


def _row_to_event(row: asyncpg.Record) -> EventRecord:
    props = row["properties"]
    common = row["common_properties"]
    if isinstance(props, str):
        props = json.loads(props)
    if isinstance(common, str):
        common = json.loads(common)
    return EventRecord(
        event_id=row["event_id"],
        name=row["name"],
        properties=props or {},
        common_properties=common or {},
        distinct_id=row["distinct_id"],
        anonymous_id=row["anonymous_id"],
        session_id=row["session_id"],
        event_time=row["event_time"],
        received_at=row["received_at"],
    )


def _row_to_user(row: asyncpg.Record) -> UserRecord:
    return UserRecord(
        user_id=row["user_id"],
        distinct_id=row["distinct_id"],
        anonymous_id=row["anonymous_id"],
        first_seen_at=row["first_seen_at"],
        last_seen_at=row["last_seen_at"],
        first_open_at=row["first_open_at"],
        signup_at=row["signup_at"],
        is_paid=bool(row["is_paid"]),
        total_revenue=float(row["total_revenue"] or 0),
        channel=row["channel"],
    )


async def overview(pool: asyncpg.Pool, frm: datetime, to: datetime) -> OverviewStats:
    stats = OverviewStats()
    from_date, to_date = inclusive_date_range(frm, to)
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT
                COALESCE(SUM(dau), 0),
                COALESCE(SUM(new_users), 0),
                COALESCE(SUM(installs), 0),
                COALESCE(SUM(revenue), 0),
                COALESCE(SUM(paying_users), 0),
                COALESCE(SUM(total_events), 0)
            FROM daily_stats
            WHERE date >= $1::date AND date <= $2::date
            """,
            from_date,
            to_date,
        )
        if row:
            stats.dau = int(row[0])
            stats.new_users = int(row[1])
            stats.installs = int(row[2])
            stats.revenue = float(row[3] or 0)
            stats.paying_users = int(row[4])
            stats.total_events = int(row[5])

        active = await conn.fetchval(
            """
            SELECT COALESCE(active_subscriptions, 0)
            FROM daily_stats
            WHERE date >= $1::date AND date <= $2::date
            ORDER BY date DESC
            LIMIT 1
            """,
            from_date,
            to_date,
        )
        stats.active_subscriptions = int(active or 0)

        if stats.total_events == 0:
            stats.total_events = int(
                await conn.fetchval(
                    "SELECT COUNT(*) FROM events WHERE event_time >= $1 AND event_time < $2",
                    frm,
                    to,
                )
                or 0
            )
            stats.dau = int(
                await conn.fetchval(
                    f"""
                    SELECT COUNT(DISTINCT {_resolved_user_sql('e')})
                    FROM events e WHERE e.event_time >= $1 AND e.event_time < $2
                    """,
                    frm,
                    to,
                )
                or 0
            )

        top_rows = await conn.fetch(
            """
            SELECT name, COUNT(*) AS cnt
            FROM events
            WHERE event_time >= $1 AND event_time < $2
            GROUP BY name
            ORDER BY cnt DESC
            LIMIT 10
            """,
            frm,
            to,
        )
        stats.top_events = [NamedCount(name=r["name"], count=int(r["cnt"])) for r in top_rows]

        trend_rows = await conn.fetch(
            """
            SELECT
                TO_CHAR(ds.date, 'YYYY-MM-DD') AS day,
                COALESCE(ds.total_events, 0) AS cnt,
                COALESCE(ds.dau, 0) AS users,
                COALESCE(ds.new_users, 0) AS new_users,
                COALESCE(ds.installs, 0) AS installs,
                COALESCE(ds.revenue, 0) AS revenue,
                COALESCE(ds.active_subscriptions, 0) AS active_subscriptions
            FROM daily_stats ds
            WHERE ds.date >= $1::date AND ds.date <= $2::date
            ORDER BY ds.date
            """,
            from_date,
            to_date,
        )
        stats.trend = [
            DailyEventStat(
                date=r["day"],
                count=int(r["cnt"]),
                users=int(r["users"]),
                new_users=int(r["new_users"]),
                installs=int(r["installs"]),
                revenue=float(r["revenue"] or 0),
                active_subscriptions=int(r["active_subscriptions"]),
            )
            for r in trend_rows
        ]

        if not stats.trend:
            fallback = await conn.fetch(
                f"""
                SELECT
                    TO_CHAR(DATE(e.event_time AT TIME ZONE 'UTC'), 'YYYY-MM-DD') AS day,
                    COUNT(*) AS cnt,
                    COUNT(DISTINCT {_resolved_user_sql('e')}) AS users
                FROM events e
                WHERE e.event_time >= $1 AND e.event_time < $2
                GROUP BY day
                ORDER BY day
                """,
                frm,
                to,
            )
            stats.trend = [
                DailyEventStat(date=r["day"], count=int(r["cnt"]), users=int(r["users"]))
                for r in fallback
            ]
    return stats


async def event_names(pool: asyncpg.Pool, q: str) -> list[NamedCount]:
    q = (q or "").strip()
    async with pool.acquire() as conn:
        if not q:
            rows = await conn.fetch(
                """
                SELECT name, COUNT(*) AS cnt FROM events
                GROUP BY name ORDER BY cnt DESC LIMIT 100
                """
            )
        else:
            rows = await conn.fetch(
                """
                SELECT name, COUNT(*) AS cnt FROM events
                WHERE name ILIKE $1
                GROUP BY name ORDER BY cnt DESC LIMIT 100
                """,
                f"%{q}%",
            )
    return [NamedCount(name=r["name"], count=int(r["cnt"])) for r in rows]


async def event_trend(
    pool: asyncpg.Pool,
    event_name: str,
    frm: datetime,
    to: datetime,
    unit: str,
    filters: list[EventFilter] | None,
) -> list[EventTrendPoint]:
    trunc = "day"
    if unit == "hour":
        trunc = "hour"
    elif unit == "week":
        trunc = "week"

    query = f"""
        SELECT
            TO_CHAR(DATE_TRUNC('{trunc}', event_time AT TIME ZONE 'UTC'), 'YYYY-MM-DD HH24:MI') AS bucket,
            COUNT(*) AS cnt,
            COUNT(DISTINCT {_resolved_user_sql('events')}) AS users
        FROM events
        WHERE event_time >= $1 AND event_time < $2
    """
    args: list[Any] = [frm, to]
    next_idx = 3
    if event_name:
        query += f" AND name = ${next_idx}"
        args.append(event_name)
        next_idx += 1
    filter_sql, filter_args, _ = append_event_filters(filters, next_idx)
    query += filter_sql + " GROUP BY bucket ORDER BY bucket"
    args.extend(filter_args)

    async with pool.acquire() as conn:
        rows = await conn.fetch(query, *args)
    return [
        EventTrendPoint(bucket=r["bucket"], count=int(r["cnt"]), users=int(r["users"]))
        for r in rows
    ]


async def list_events(
    pool: asyncpg.Pool,
    event_name: str,
    frm: datetime,
    to: datetime,
    limit: int,
    offset: int,
    filters: list[EventFilter] | None,
) -> tuple[list[EventRecord], int]:
    if limit <= 0:
        limit = 50
    if limit > 200:
        limit = 200

    where = "WHERE event_time >= $1 AND event_time < $2"
    args: list[Any] = [frm, to]
    next_idx = 3
    if event_name:
        where += f" AND name = ${next_idx}"
        args.append(event_name)
        next_idx += 1
    filter_sql, filter_args, next_idx = append_event_filters(filters, next_idx)
    where += filter_sql
    args.extend(filter_args)

    async with pool.acquire() as conn:
        total = int(await conn.fetchval(f"SELECT COUNT(*) FROM events {where}", *args) or 0)
        rows = await conn.fetch(
            f"""
            SELECT event_id, name, properties, common_properties, distinct_id,
                   anonymous_id, session_id, event_time, received_at
            FROM events {where}
            ORDER BY event_time DESC
            LIMIT ${next_idx} OFFSET ${next_idx + 1}
            """,
            *args,
            limit,
            offset,
        )
    return [_row_to_event(r) for r in rows], total


async def property_values(
    pool: asyncpg.Pool, source: str, field: str, event_name: str, limit: int
) -> list[str]:
    field = (field or "").strip()
    if not SAFE_JSON_KEY.match(field):
        return []
    if limit <= 0 or limit > 100:
        limit = 50
    col = "common_properties"
    if source in ("properties", "prop", "event"):
        col = "properties"

    query = f"""
        SELECT DISTINCT COALESCE({col}->>'{field}', '') AS val
        FROM events
        WHERE COALESCE({col}->>'{field}', '') <> ''
    """
    args: list[Any] = []
    next_idx = 1
    if event_name:
        query += f" AND name = ${next_idx}"
        args.append(event_name)
        next_idx += 1
    query += f" ORDER BY val LIMIT ${next_idx}"
    args.append(limit)

    async with pool.acquire() as conn:
        rows = await conn.fetch(query, *args)
    return [r["val"] for r in rows]


async def funnel(
    pool: asyncpg.Pool, steps: list[str], frm: datetime, to: datetime, window_hours: int
) -> FunnelResult:
    if not steps:
        return FunnelResult(steps=[])
    if window_hours <= 0:
        window_hours = 24
    window = f"{window_hours} hours"

    cte = "WITH "
    args: list[Any] = [frm, to]
    arg_idx = 3
    uid = _resolved_user_sql("events")
    euid = _resolved_user_sql("e")
    for i, step in enumerate(steps):
        if i == 0:
            cte += f"""
                step{i} AS (
                    SELECT DISTINCT {uid} AS user_id,
                           MIN(event_time) AS step_time
                    FROM events
                    WHERE event_time >= $1 AND event_time < $2 AND name = ${arg_idx}
                    GROUP BY 1
                )"""
            args.append(step)
            arg_idx += 1
        else:
            cte += f"""
                , step{i} AS (
                    SELECT s.user_id, MIN(e.event_time) AS step_time
                    FROM step{i - 1} s
                    JOIN events e ON {euid} = s.user_id
                    WHERE e.name = ${arg_idx}
                      AND e.event_time > s.step_time
                      AND e.event_time <= s.step_time + INTERVAL '{window}'
                    GROUP BY s.user_id
                )"""
            args.append(step)
            arg_idx += 1

    unions = " UNION ALL ".join(
        f"SELECT {i} AS step_idx, COUNT(*) AS users FROM step{i}" for i in range(len(steps))
    )
    query = cte + " " + unions + " ORDER BY step_idx"

    async with pool.acquire() as conn:
        rows = await conn.fetch(query, *args)

    result = FunnelResult(steps=[])
    first_users = 1
    for r in rows:
        idx = int(r["step_idx"])
        users = int(r["users"])
        if idx == 0:
            first_users = users if users > 0 else 1
        result.steps.append(
            FunnelStep(
                name=steps[idx],
                users=users,
                conversion=users / first_users * 100,
            )
        )
    return result


async def retention(
    pool: asyncpg.Pool,
    cohort_event: str,
    return_event: str,
    frm: datetime,
    to: datetime,
    days: int,
) -> RetentionResult:
    if days <= 0:
        days = 7
    if not cohort_event:
        cohort_event = "app_start"
    if not return_event:
        return_event = cohort_event

    day_list = list(range(days + 1))
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            f"""
            WITH cohort AS (
                SELECT
                    {_resolved_user_sql('events')} AS user_id,
                    DATE(MIN(event_time) AT TIME ZONE 'UTC') AS cohort_date
                FROM events
                WHERE name = $1
                  AND event_time >= $2 AND event_time < $3
                GROUP BY 1
            ),
            returns AS (
                SELECT
                    c.cohort_date,
                    c.user_id,
                    DATE(e.event_time AT TIME ZONE 'UTC') AS return_date
                FROM cohort c
                JOIN events e ON {_resolved_user_sql('e')} = c.user_id
                WHERE e.name = $4
                  AND e.event_time >= $2 AND e.event_time < $3
            )
            SELECT
                TO_CHAR(cohort_date, 'YYYY-MM-DD') AS cohort_date,
                COUNT(DISTINCT user_id) AS cohort_size,
                day_offset,
                COUNT(DISTINCT user_id) FILTER (WHERE returned) AS retained
            FROM (
                SELECT
                    c.cohort_date,
                    c.user_id,
                    d.day_offset,
                    EXISTS (
                        SELECT 1 FROM returns r
                        WHERE r.user_id = c.user_id
                          AND r.cohort_date = c.cohort_date
                          AND r.return_date = c.cohort_date + (d.day_offset || ' days')::interval
                    ) AS returned
                FROM cohort c
                CROSS JOIN generate_series(0, $5) AS d(day_offset)
            ) t
            GROUP BY cohort_date, day_offset
            ORDER BY cohort_date, day_offset
            """,
            cohort_event,
            frm,
            to,
            return_event,
            days,
        )

    row_map: dict[str, RetentionRow] = {}
    order: list[str] = []
    for r in rows:
        cohort_date = r["cohort_date"]
        cohort_size = int(r["cohort_size"])
        day_offset = int(r["day_offset"])
        retained = int(r["retained"])
        if cohort_date not in row_map:
            row_map[cohort_date] = RetentionRow(
                cohort_date=cohort_date,
                cohort_size=cohort_size,
                retention=[0.0] * (days + 1),
            )
            order.append(cohort_date)
        if cohort_size > 0:
            row_map[cohort_date].retention[day_offset] = retained / cohort_size * 100

    return RetentionResult(days=day_list, rows=[row_map[d] for d in order])


async def list_users(
    pool: asyncpg.Pool, query: str, limit: int, offset: int
) -> tuple[list[UserRecord], int]:
    if limit <= 0:
        limit = 50
    if limit > 200:
        limit = 200

    count_q = "SELECT COUNT(*) FROM users"
    list_q = """
        SELECT user_id, distinct_id, anonymous_id, first_seen_at, last_seen_at,
               first_open_at, signup_at, is_paid, total_revenue, channel
        FROM users
    """
    args: list[Any] = []
    if query:
        filt = """
            WHERE user_id ILIKE $1
               OR COALESCE(distinct_id, '') ILIKE $1
               OR anonymous_id ILIKE $1
        """
        count_q += filt
        list_q += filt
        args.append(f"%{query}%")
    list_q += f" ORDER BY last_seen_at DESC LIMIT ${len(args)+1} OFFSET ${len(args)+2}"

    async with pool.acquire() as conn:
        total = int(await conn.fetchval(count_q, *args) or 0)
        rows = await conn.fetch(list_q, *args, limit, offset)
    return [_row_to_user(r) for r in rows], total


async def get_user(pool: asyncpg.Pool, user_id: str) -> UserRecord | None:
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT user_id, distinct_id, anonymous_id, first_seen_at, last_seen_at,
                   first_open_at, signup_at, is_paid, total_revenue, channel
            FROM users WHERE user_id = $1
            """,
            user_id,
        )
        if row is None:
            row = await conn.fetchrow(
                """
                SELECT user_id, distinct_id, anonymous_id, first_seen_at, last_seen_at,
                       first_open_at, signup_at, is_paid, total_revenue, channel
                FROM users
                WHERE anonymous_id = $1
                  AND distinct_id IS NOT NULL AND distinct_id != ''
                ORDER BY last_seen_at DESC
                LIMIT 1
                """,
                user_id,
            )
    return _row_to_user(row) if row else None


async def list_user_events(
    pool: asyncpg.Pool,
    user_id: str,
    frm: datetime,
    to: datetime,
    limit: int,
    offset: int,
    order: str = "desc",
    event_name: str = "",
) -> tuple[list[EventRecord], int] | None:
    user = await get_user(pool, user_id)
    if user is None:
        return None
    if limit <= 0:
        limit = 50
    if limit > 1000:
        limit = 1000

    ids = []
    for v in (user.user_id, user.anonymous_id, user.distinct_id or ""):
        if v and v not in ids:
            ids.append(v)

    order_sql = "DESC" if (order or "").lower() != "asc" else "ASC"
    name_filter = (event_name or "").strip()
    where = """
        event_time >= $1 AND event_time < $2
          AND (distinct_id = ANY($3) OR anonymous_id = ANY($3))
    """
    args: list[Any] = [frm, to, ids]
    if name_filter:
        where += f" AND name = ${len(args) + 1}"
        args.append(name_filter)
    else:
        # app_log 已拆到 app_logs；排除残留行，避免时间线被日志淹没
        where += " AND name <> 'app_log'"

    async with pool.acquire() as conn:
        total = int(
            await conn.fetchval(f"SELECT COUNT(*) FROM events WHERE {where}", *args) or 0
        )
        limit_idx = len(args) + 1
        offset_idx = len(args) + 2
        rows = await conn.fetch(
            f"""
            SELECT event_id, name, properties, common_properties, distinct_id,
                   anonymous_id, session_id, event_time, received_at
            FROM events
            WHERE {where}
            ORDER BY event_time {order_sql}
            LIMIT ${limit_idx} OFFSET ${offset_idx}
            """,
            *args,
            limit,
            offset,
        )
    return [_row_to_event(r) for r in rows], total

async def delete_user(pool: asyncpg.Pool, user_id: str) -> dict[str, int] | None:
    """删除用户及其相关埋点 / 日志 / 衍生数据。"""
    user = await get_user(pool, user_id)
    if user is None:
        return None

    ids: list[str] = []
    for v in (user.user_id, user.anonymous_id, user.distinct_id or ""):
        if v and v not in ids:
            ids.append(v)
    uid = user.user_id

    async with pool.acquire() as conn:
        async with conn.transaction():
            events_n = int(
                await conn.fetchval(
                    """
                    WITH d AS (
                        DELETE FROM events
                        WHERE distinct_id = ANY($1) OR anonymous_id = ANY($1)
                        RETURNING 1
                    )
                    SELECT COUNT(*) FROM d
                    """,
                    ids,
                )
                or 0
            )
            logs_n = int(
                await conn.fetchval(
                    """
                    WITH d AS (
                        DELETE FROM app_logs
                        WHERE user_id = ANY($1)
                           OR anonymous_id = ANY($1)
                           OR distinct_id = ANY($1)
                        RETURNING 1
                    )
                    SELECT COUNT(*) FROM d
                    """,
                    ids,
                )
                or 0
            )
            stab_n = int(
                await conn.fetchval(
                    """
                    WITH d AS (
                        DELETE FROM stability_events
                        WHERE user_id = ANY($1)
                           OR anonymous_id = ANY($1)
                           OR distinct_id = ANY($1)
                        RETURNING 1
                    )
                    SELECT COUNT(*) FROM d
                    """,
                    ids,
                )
                or 0
            )
            await conn.execute(
                "DELETE FROM stability_issue_users WHERE user_id = ANY($1)",
                ids,
            )
            await conn.execute("DELETE FROM subscriptions WHERE user_id = $1", uid)
            for table in (
                "daily_active_users",
                "daily_paying_users",
                "daily_install_users",
            ):
                await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", uid)
            await conn.execute("DELETE FROM users WHERE user_id = $1", uid)

    return {
        "events": events_n,
        "app_logs": logs_n,
        "stability_events": stab_n,
    }

