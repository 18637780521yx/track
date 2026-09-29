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
