from datetime import datetime

import asyncpg

from app.models import DailyEventStat, NamedCount, OverviewStats


async def list_apps(pool: asyncpg.Pool) -> list[dict]:
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT DISTINCT ON (package) package, name
            FROM (
                SELECT common_properties->>'app_package' AS package,
                       NULLIF(common_properties->>'app_name', '') AS name,
                       event_time, id
                FROM events
            ) apps
            WHERE package <> ''
            ORDER BY package, name IS NULL, event_time DESC, id DESC
            """
        )
    return [dict(row) for row in rows]


async def overview(
    pool: asyncpg.Pool, frm: datetime, to: datetime, app_package: str
) -> OverviewStats:
    async with pool.acquire() as conn, conn.transaction(isolation="repeatable_read", readonly=True):
        rows = await conn.fetch(
            """
            WITH app_events AS (
                SELECT event_time, name, anonymous_id, NULLIF(distinct_id, '') AS distinct_id
                FROM events
                WHERE common_properties->>'app_package' = $3 AND event_time < $2
            ), identities AS (
                SELECT DISTINCT ON (anonymous_id) anonymous_id, distinct_id
                FROM app_events
                WHERE distinct_id IS NOT NULL AND anonymous_id <> ''
                ORDER BY anonymous_id, event_time DESC, distinct_id
            ), activity AS (
                SELECT e.event_time, e.name,
                       COALESCE(e.distinct_id, i.distinct_id, e.anonymous_id) AS user_id
                FROM app_events e
                LEFT JOIN identities i USING (anonymous_id)
            ), first_activity AS (
                SELECT user_id, MIN(event_time) AS first_seen,
                       MIN(event_time) FILTER (WHERE name = 'app_first_open') AS first_open
                FROM activity
                GROUP BY user_id
            )
            SELECT TO_CHAR(a.event_time AT TIME ZONE 'UTC', 'YYYY-MM-DD') AS day,
                   COUNT(*) AS cnt,
                   COUNT(DISTINCT a.user_id) AS users,
                   COUNT(DISTINCT a.user_id) FILTER (WHERE a.event_time = f.first_seen) AS new_users,
                   COUNT(DISTINCT a.user_id) FILTER (
                       WHERE a.name = 'app_first_open' AND a.event_time = f.first_open
                   ) AS installs
            FROM activity a
            JOIN first_activity f USING (user_id)
            WHERE a.event_time >= $1
            GROUP BY day
            ORDER BY day
            """,
            frm,
            to,
            app_package,
        )
        top = await conn.fetch(
            """
            SELECT name, COUNT(*) AS cnt
            FROM events
            WHERE event_time >= $1 AND event_time < $2
              AND common_properties->>'app_package' = $3
            GROUP BY name
            ORDER BY cnt DESC, name
            LIMIT 10
            """,
            frm,
            to,
            app_package,
        )
    return OverviewStats(
        dau=sum(row["users"] for row in rows),
        new_users=sum(row["new_users"] for row in rows),
        installs=sum(row["installs"] for row in rows),
        total_events=sum(row["cnt"] for row in rows),
        top_events=[NamedCount(name=row["name"], count=row["cnt"]) for row in top],
        trend=[
            DailyEventStat(
                date=row["day"], count=row["cnt"], users=row["users"],
                new_users=row["new_users"], installs=row["installs"],
            )
            for row in rows
        ],
    )
