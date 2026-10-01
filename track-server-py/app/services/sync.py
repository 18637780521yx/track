from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

import asyncpg

from app.models import TrackEvent

EVENT_APP_FIRST_OPEN = "app_first_open"
EVENT_USER_SIGNUP = "user_signup"
EVENT_PAYMENT_SUCCESS = "payment_success"
EVENT_SUBSCRIPTION_START = "subscription_start"
EVENT_SUBSCRIPTION_RENEW = "subscription_renew"
EVENT_SUBSCRIPTION_CANCEL = "subscription_cancel"


def resolve_user_id(e: TrackEvent) -> str:
    if e.distinct_id:
        return e.distinct_id
    if e.anonymous_id:
        return e.anonymous_id
    return "unknown"


def prop_string(m: dict[str, Any] | None, key: str) -> str:
    if not m or key not in m or m[key] is None:
        return ""
    v = m[key]
    return v if isinstance(v, str) else str(v)


def prop_float(m: dict[str, Any] | None, key: str) -> float:
    if not m or key not in m or m[key] is None:
        return 0.0
    v = m[key]
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def prop_time(m: dict[str, Any] | None, key: str) -> datetime | None:
    s = prop_string(m, key)
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


async def sync_derived_tables(conn: asyncpg.Connection, e: TrackEvent) -> None:
    user_id = resolve_user_id(e)
    ts = e.timestamp or datetime.now(timezone.utc)
    day = ts.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)

    # 匿名 → 登录关联：同一 anonymous_id 下出现 distinct_id（含 identify 事件）时合并画像
    if e.distinct_id and e.anonymous_id and e.anonymous_id not in ("", "unknown"):
        if e.distinct_id != e.anonymous_id:
            await merge_anonymous_into_distinct(conn, e.distinct_id, e.anonymous_id, ts)

    is_new = await upsert_user(conn, e, user_id, ts)
    await touch_daily_stats(conn, day, user_id)

    if e.name == EVENT_PAYMENT_SUCCESS:
        amount = prop_float(e.properties, "amount")
        if amount > 0:
            await bump_daily_revenue(conn, day, amount)
            await bump_daily_paying_user(conn, day, user_id)
    elif e.name == EVENT_SUBSCRIPTION_START:
        await handle_subscription_start(conn, e, user_id, ts)
    elif e.name == EVENT_SUBSCRIPTION_RENEW:
        await handle_subscription_renew(conn, e, user_id, ts)
    elif e.name == EVENT_SUBSCRIPTION_CANCEL:
        await handle_subscription_cancel(conn, user_id, ts)

    await refresh_active_subscriptions(conn, day)
    _ = is_new


async def merge_anonymous_into_distinct(
    conn: asyncpg.Connection, distinct_id: str, anonymous_id: str, ts: datetime
) -> None:
    """把以 anonymous_id 为 user_id 的画像/日活合并到 distinct_id，避免登录前后拆成两人。"""
    if not distinct_id or not anonymous_id or distinct_id == anonymous_id:
        return

    anon = await conn.fetchrow("SELECT * FROM users WHERE user_id = $1", anonymous_id)
    canon = await conn.fetchrow("SELECT * FROM users WHERE user_id = $1", distinct_id)

    if anon is None and canon is None:
        return

    if canon is None and anon is not None:
        # 先插入 canonical，再迁附属表、删匿名行（避免直接改 PK 触发 subscriptions FK）
        await conn.execute(
            """
            INSERT INTO users (
                user_id, distinct_id, anonymous_id,
                first_seen_at, last_seen_at, first_open_at, signup_at,
                is_paid, total_revenue, channel, properties
            ) VALUES ($1, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            """,
            distinct_id,
            anonymous_id,
            anon["first_seen_at"],
            anon["last_seen_at"],
            anon["first_open_at"],
            anon["signup_at"],
            bool(anon["is_paid"]),
            anon["total_revenue"],
            anon["channel"],
            anon["properties"],
        )
        await _remap_user_children(conn, from_id=anonymous_id, to_id=distinct_id)
        await conn.execute("DELETE FROM users WHERE user_id = $1", anonymous_id)
        return

    if anon is not None and canon is not None and anon["user_id"] != canon["user_id"]:
        await conn.execute(
            """
            UPDATE users SET
                distinct_id = COALESCE(users.distinct_id, $2),
                anonymous_id = CASE
                    WHEN users.anonymous_id IN ('', 'unknown') THEN $3
                    ELSE users.anonymous_id
                END,
                first_seen_at = LEAST(users.first_seen_at, $4::timestamptz),
                last_seen_at = GREATEST(users.last_seen_at, $5::timestamptz),
                first_open_at = CASE
                    WHEN users.first_open_at IS NULL THEN $6::timestamptz
                    WHEN $6::timestamptz IS NULL THEN users.first_open_at
                    ELSE LEAST(users.first_open_at, $6::timestamptz)
                END,
                signup_at = CASE
                    WHEN users.signup_at IS NULL THEN $7::timestamptz
                    WHEN $7::timestamptz IS NULL THEN users.signup_at
                    ELSE LEAST(users.signup_at, $7::timestamptz)
                END,
                is_paid = users.is_paid OR $8::boolean,
                total_revenue = users.total_revenue + $9::numeric,
                channel = COALESCE(users.channel, $10),
                updated_at = NOW()
            WHERE user_id = $1
            """,
            distinct_id,
            distinct_id,
            anonymous_id,
            anon["first_seen_at"],
            anon["last_seen_at"],
            anon["first_open_at"],
            anon["signup_at"],
            bool(anon["is_paid"]),
            float(anon["total_revenue"] or 0),
            anon["channel"],
        )
        await _remap_user_children(conn, from_id=anonymous_id, to_id=distinct_id)
        await conn.execute("DELETE FROM users WHERE user_id = $1", anonymous_id)
        return

    # 仅写回 anonymous_id 到已登录用户
    await conn.execute(
        """
        UPDATE users SET
            anonymous_id = CASE
                WHEN anonymous_id IN ('', 'unknown') THEN $2
                ELSE anonymous_id
            END,
            distinct_id = COALESCE(distinct_id, $1),
            last_seen_at = GREATEST(last_seen_at, $3),
            updated_at = NOW()
        WHERE user_id = $1
        """,
        distinct_id,
        anonymous_id,
        ts,
    )


async def _remap_user_children(conn: asyncpg.Connection, from_id: str, to_id: str) -> None:
    for table in ("daily_active_users", "daily_install_users", "daily_paying_users"):
        await conn.execute(
            f"""
            INSERT INTO {table} (date, user_id)
            SELECT date, $1 FROM {table} WHERE user_id = $2
            ON CONFLICT DO NOTHING
            """,
            to_id,
            from_id,
        )
        await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", from_id)

    await conn.execute(
        "UPDATE subscriptions SET user_id = $1 WHERE user_id = $2",
        to_id,
        from_id,
    )
    # stability 表可能尚未迁移；忽略缺失
    try:
        await conn.execute(
            """
            INSERT INTO stability_issue_users (fingerprint, user_id, first_seen_at)
            SELECT fingerprint, $1, first_seen_at FROM stability_issue_users WHERE user_id = $2
            ON CONFLICT DO NOTHING
            """,
            to_id,
            from_id,
        )
        await conn.execute(
            "DELETE FROM stability_issue_users WHERE user_id = $1", from_id
        )
        await conn.execute(
            "UPDATE stability_events SET user_id = $1 WHERE user_id = $2",
            to_id,
            from_id,
        )
    except asyncpg.UndefinedTableError:
        pass
    try:
        await conn.execute(
            "UPDATE app_logs SET user_id = $1 WHERE user_id = $2",
            to_id,
            from_id,
        )
    except asyncpg.UndefinedTableError:
        pass


async def upsert_user(
    conn: asyncpg.Connection, e: TrackEvent, user_id: str, ts: datetime
) -> bool:
    channel = prop_string(e.common_properties, "channel") or prop_string(e.properties, "channel")
    row = await conn.fetchrow(
        """
        INSERT INTO users (
            user_id, distinct_id, anonymous_id,
            first_seen_at, last_seen_at, channel
        ) VALUES ($1, $2, $3, $4, $4, NULLIF($5, ''))
        ON CONFLICT (user_id) DO UPDATE SET
            distinct_id = COALESCE(EXCLUDED.distinct_id, users.distinct_id),
            anonymous_id = CASE
                WHEN EXCLUDED.anonymous_id IS NOT NULL
                     AND EXCLUDED.anonymous_id NOT IN ('', 'unknown')
                THEN EXCLUDED.anonymous_id
                ELSE users.anonymous_id
            END,
            last_seen_at = GREATEST(users.last_seen_at, EXCLUDED.last_seen_at),
            channel = COALESCE(users.channel, EXCLUDED.channel),
            updated_at = NOW()
        RETURNING (xmax = 0) AS is_new
        """,
        user_id,
        e.distinct_id,
        e.anonymous_id or "unknown",
        ts,
        channel,
    )
    is_new = bool(row["is_new"]) if row else False

    if e.name == EVENT_APP_FIRST_OPEN:
        had = await conn.fetchval(
            "SELECT first_open_at IS NOT NULL FROM users WHERE user_id = $1", user_id
        )
        await conn.execute(
            """
            UPDATE users SET first_open_at = LEAST(COALESCE(first_open_at, $2), $2), updated_at = NOW()
            WHERE user_id = $1
            """,
            user_id,
            ts,
        )
        if not had:
            day = ts.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
            await bump_daily_install(conn, day, user_id)
    elif e.name == EVENT_USER_SIGNUP:
        await conn.execute(
            """
            UPDATE users SET signup_at = LEAST(COALESCE(signup_at, $2), $2), updated_at = NOW()
            WHERE user_id = $1
            """,
            user_id,
            ts,
        )
    elif e.name == EVENT_PAYMENT_SUCCESS:
        amount = prop_float(e.properties, "amount")
        if amount > 0:
            await conn.execute(
                """
                UPDATE users SET
                    is_paid = TRUE,
                    total_revenue = total_revenue + $2,
                    updated_at = NOW()
                WHERE user_id = $1
                """,
                user_id,
                amount,
            )

    if is_new:
        day = ts.astimezone(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        await bump_daily_counter(conn, day, "new_users", 1)
    return is_new


async def touch_daily_stats(conn: asyncpg.Connection, day: datetime, user_id: str) -> None:
    await conn.execute(
        """
        INSERT INTO daily_stats (date, total_events)
        VALUES ($1::date, 1)
        ON CONFLICT (date) DO UPDATE SET
            total_events = daily_stats.total_events + 1,
            updated_at = NOW()
        """,
        day,
    )
    inserted = await conn.fetchval(
        """
        INSERT INTO daily_active_users (date, user_id)
        VALUES ($1::date, $2)
        ON CONFLICT DO NOTHING
        RETURNING TRUE
        """,
        day,
        user_id,
    )
    if inserted:
        await bump_daily_counter(conn, day, "dau", 1)


async def bump_daily_counter(
    conn: asyncpg.Connection, day: datetime, column: str, delta: int
) -> None:
    allowed = {"dau", "new_users", "installs", "paying_users", "total_events", "active_subscriptions"}
    if column not in allowed:
        raise ValueError(f"invalid column {column}")
    await conn.execute(
        f"""
        INSERT INTO daily_stats (date, {column})
        VALUES ($1::date, $2)
        ON CONFLICT (date) DO UPDATE SET
            {column} = daily_stats.{column} + $2,
            updated_at = NOW()
        """,
        day,
        delta,
    )


async def bump_daily_revenue(conn: asyncpg.Connection, day: datetime, amount: float) -> None:
    await conn.execute(
        """
        INSERT INTO daily_stats (date, revenue)
        VALUES ($1::date, $2)
        ON CONFLICT (date) DO UPDATE SET
            revenue = daily_stats.revenue + $2,
            updated_at = NOW()
        """,
        day,
        amount,
    )


async def bump_daily_install(conn: asyncpg.Connection, day: datetime, user_id: str) -> None:
    inserted = await conn.fetchval(
        """
        INSERT INTO daily_install_users (date, user_id)
        VALUES ($1::date, $2)
        ON CONFLICT DO NOTHING
        RETURNING TRUE
        """,
        day,
        user_id,
    )
    if inserted:
        await bump_daily_counter(conn, day, "installs", 1)


async def bump_daily_paying_user(conn: asyncpg.Connection, day: datetime, user_id: str) -> None:
    inserted = await conn.fetchval(
        """
        INSERT INTO daily_paying_users (date, user_id)
        VALUES ($1::date, $2)
        ON CONFLICT DO NOTHING
        RETURNING TRUE
        """,
        day,
        user_id,
    )
    if inserted:
        await bump_daily_counter(conn, day, "paying_users", 1)


async def handle_subscription_start(
    conn: asyncpg.Connection, e: TrackEvent, user_id: str, ts: datetime
) -> None:
    plan = prop_string(e.properties, "plan") or "unknown"
    amount = prop_float(e.properties, "amount")
    currency = prop_string(e.properties, "currency") or "CNY"
    expires_at = prop_time(e.properties, "expires_at")
    await conn.execute(
        """
        INSERT INTO subscriptions (user_id, plan, status, amount, currency, started_at, expires_at)
        VALUES ($1, $2, 'active', $3, $4, $5, $6)
        """,
        user_id,
        plan,
        amount,
        currency,
        ts,
        expires_at,
    )


async def handle_subscription_renew(
    conn: asyncpg.Connection, e: TrackEvent, user_id: str, ts: datetime
) -> None:
    expires_at = prop_time(e.properties, "expires_at")
    await conn.execute(
        """
        UPDATE subscriptions SET
            status = 'active',
            expires_at = COALESCE($2, expires_at),
            updated_at = NOW()
        WHERE id = (
            SELECT id FROM subscriptions WHERE user_id = $1 ORDER BY started_at DESC LIMIT 1
        )
        """,
        user_id,
        expires_at,
    )


async def handle_subscription_cancel(
    conn: asyncpg.Connection, user_id: str, ts: datetime
) -> None:
    await conn.execute(
        """
        UPDATE subscriptions SET
            status = 'cancelled',
            cancelled_at = $2,
            updated_at = NOW()
        WHERE user_id = $1 AND status = 'active'
        """,
        user_id,
        ts,
    )


async def refresh_active_subscriptions(conn: asyncpg.Connection, day: datetime) -> None:
    count = await conn.fetchval("SELECT COUNT(*) FROM subscriptions WHERE status = 'active'")
    await conn.execute(
        """
        INSERT INTO daily_stats (date, active_subscriptions)
        VALUES ($1::date, $2)
        ON CONFLICT (date) DO UPDATE SET
            active_subscriptions = $2,
            updated_at = NOW()
        """,
        day,
        count or 0,
    )


async def ingest(pool: asyncpg.Pool, events: list[TrackEvent]) -> tuple[int, int]:
    if not events:
        return 0, 0

    from app.services.applog import ingest_app_log, is_app_log_event
    from app.services.stability import ingest_stability, is_stability_event

    stored = 0
    dropped = 0
    async with pool.acquire() as conn:
        for e in events:
            if not e.event_id or not e.name:
                dropped += 1
                continue
            anon = e.anonymous_id or "unknown"
            session = e.session_id or "unknown"
            ts = e.timestamp or datetime.now(timezone.utc)
            e.anonymous_id = anon
            e.session_id = session
            e.timestamp = ts

            if is_stability_event(e.name):
                try:
                    ok = await ingest_stability(conn, e)
                except Exception:
                    dropped += 1
                    continue
                if ok:
                    stored += 1
                else:
                    dropped += 1
                continue

            if is_app_log_event(e.name):
                try:
                    ok = await ingest_app_log(conn, e)
                except Exception:
                    dropped += 1
                    continue
                if ok:
                    stored += 1
                else:
                    dropped += 1
                continue

            props = json.dumps(e.properties or {})
            common = json.dumps(e.common_properties or {})
            result = await conn.execute(
                """
                INSERT INTO events (
                    event_id, name, properties, common_properties,
                    distinct_id, anonymous_id, session_id, event_time
                ) VALUES ($1, $2, $3::jsonb, $4::jsonb, $5, $6, $7, $8)
                ON CONFLICT (event_id) DO NOTHING
                """,
                e.event_id,
                e.name,
                props,
                common,
                e.distinct_id,
                anon,
                session,
                ts,
            )
            # asyncpg returns "INSERT 0 1" or "INSERT 0 0"
            if result.endswith("1"):
                stored += 1
                try:
                    await sync_derived_tables(conn, e)
                except Exception:
                    pass
            else:
                dropped += 1
    return stored, dropped
