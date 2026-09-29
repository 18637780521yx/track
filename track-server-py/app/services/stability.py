from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from typing import Any

import asyncpg

from app.models import (
    StabilityEventRecord,
    StabilityIssueDetail,
    StabilityIssueSummary,
    StabilityOverview,
    StabilityTrendPoint,
    TrackEvent,
)
from app.services.parse import inclusive_date_range
from app.services.sync import prop_string, resolve_user_id, upsert_user

STABILITY_EVENT_KINDS = {
    "app_crash": "crash",
    "app_error": "error",
    "app_anr": "anr",
}

RESERVED_PROP_KEYS = {
    "exception_type",
    "message",
    "stack",
    "thread",
    "is_fatal",
    "fingerprint",
    "blocked_ms",
    "anr_source",
}


def is_stability_event(name: str) -> bool:
    return name in STABILITY_EVENT_KINDS


def kind_for_event(name: str) -> str:
    return STABILITY_EVENT_KINDS[name]


def _normalize_stack_line(line: str) -> str:
    s = line.strip()
    s = re.sub(r"\$[0-9]+", "$N", s)
    s = re.sub(r":\d+", ":N", s)
    return s


def compute_fingerprint(exception_type: str, stack: str) -> str:
    frames: list[str] = []
    for line in (stack or "").splitlines():
        line = line.strip()
        if not line or line.startswith("Caused by:"):
            continue
        frames.append(_normalize_stack_line(line))
        if len(frames) >= 8:
            break
    raw = (exception_type or "Unknown") + "|" + "|".join(frames)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def _prop_bool(m: dict[str, Any] | None, key: str, default: bool = False) -> bool:
    if not m or key not in m or m[key] is None:
        return default
    v = m[key]
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    s = str(v).strip().lower()
    if s in ("1", "true", "yes"):
        return True
    if s in ("0", "false", "no"):
        return False
    return default


def _prop_int(m: dict[str, Any] | None, key: str) -> int | None:
    if not m or key not in m or m[key] is None:
        return None
    try:
        return int(m[key])
    except (TypeError, ValueError):
        return None


async def ingest_stability(conn: asyncpg.Connection, e: TrackEvent) -> bool:
    """Insert stability event; return True if newly stored."""
    kind = kind_for_event(e.name)
    props = e.properties or {}
    common = e.common_properties or {}
    ts = e.timestamp or datetime.now(timezone.utc)
    user_id = resolve_user_id(e)

    exception_type = prop_string(props, "exception_type") or "Unknown"
    message = prop_string(props, "message")
    stack = prop_string(props, "stack")
    thread = prop_string(props, "thread")
    fingerprint = prop_string(props, "fingerprint") or compute_fingerprint(exception_type, stack)
    is_fatal = _prop_bool(props, "is_fatal", default=(kind == "crash"))
    blocked_ms = _prop_int(props, "blocked_ms")
    anr_source = prop_string(props, "anr_source") or None

    extras = {k: v for k, v in props.items() if k not in RESERVED_PROP_KEYS}

    await conn.execute(
        """
        INSERT INTO stability_issues (
            fingerprint, kind, exception_type, sample_message, sample_stack,
            occurrence_count, user_count, first_seen_at, last_seen_at
        ) VALUES ($1, $2, $3, $4, $5, 0, 0, $6, $6)
        ON CONFLICT (fingerprint) DO UPDATE SET
            last_seen_at = GREATEST(stability_issues.last_seen_at, EXCLUDED.last_seen_at),
            sample_message = CASE
                WHEN stability_issues.sample_message = '' THEN EXCLUDED.sample_message
                ELSE stability_issues.sample_message
            END,
            sample_stack = CASE
                WHEN stability_issues.sample_stack = '' THEN EXCLUDED.sample_stack
                ELSE stability_issues.sample_stack
            END,
            updated_at = NOW()
        """,
        fingerprint,
        kind,
        exception_type[:256],
        message,
        stack,
        ts,
    )

    result = await conn.execute(
        """
        INSERT INTO stability_events (
            event_id, kind, fingerprint, exception_type, message, stack, thread,
            is_fatal, blocked_ms, anr_source,
            app_version, app_build, device_model, device_os_version,
            distinct_id, anonymous_id, session_id, user_id, extras, event_time
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7,
            $8, $9, $10,
            $11, $12, $13, $14,
            $15, $16, $17, $18, $19::jsonb, $20
        )
        ON CONFLICT (event_id) DO NOTHING
        """,
        e.event_id,
        kind,
        fingerprint,
        exception_type[:256],
        message,
        stack,
        thread[:128],
        is_fatal,
        blocked_ms,
        anr_source,
        prop_string(common, "app_version")[:64],
        prop_string(common, "app_build")[:64],
        prop_string(common, "device_model")[:128],
        prop_string(common, "device_os_version")[:64],
        e.distinct_id,
        e.anonymous_id or "unknown",
        e.session_id or "unknown",
        user_id,
        json.dumps(extras),
        ts,
    )
    if not result.endswith("1"):
        return False

    await conn.execute(
        """
        UPDATE stability_issues SET
            occurrence_count = occurrence_count + 1,
            last_seen_at = GREATEST(last_seen_at, $2),
            updated_at = NOW()
        WHERE fingerprint = $1
        """,
        fingerprint,
        ts,
    )

    new_user = await conn.fetchval(
        """
        INSERT INTO stability_issue_users (fingerprint, user_id, first_seen_at)
        VALUES ($1, $2, $3)
        ON CONFLICT DO NOTHING
        RETURNING TRUE
        """,
        fingerprint,
        user_id,
        ts,
    )
    if new_user:
        await conn.execute(
            """
            UPDATE stability_issues SET user_count = user_count + 1, updated_at = NOW()
            WHERE fingerprint = $1
            """,
            fingerprint,
        )

    try:
        await upsert_user(conn, e, user_id, ts)
    except Exception:
        pass
    return True


def _row_to_issue(row: asyncpg.Record) -> StabilityIssueSummary:
    return StabilityIssueSummary(
        fingerprint=row["fingerprint"],
        kind=row["kind"],
        exception_type=row["exception_type"] or "",
        sample_message=row["sample_message"] or "",
        sample_stack=row["sample_stack"] or "",
        occurrence_count=int(row["occurrence_count"] or 0),
        user_count=int(row["user_count"] or 0),
        first_seen_at=row["first_seen_at"],
        last_seen_at=row["last_seen_at"],
        status=row["status"] or "open",
    )


def _row_to_event(row: asyncpg.Record) -> StabilityEventRecord:
    extras = row["extras"]
    if isinstance(extras, str):
        try:
            extras = json.loads(extras)
        except json.JSONDecodeError:
            extras = {}
    elif extras is None:
        extras = {}
    return StabilityEventRecord(
        event_id=row["event_id"],
        kind=row["kind"],
        fingerprint=row["fingerprint"],
        exception_type=row["exception_type"] or "",
        message=row["message"] or "",
        stack=row["stack"] or "",
        thread=row["thread"] or "",
        is_fatal=bool(row["is_fatal"]),
        blocked_ms=row["blocked_ms"],
        anr_source=row["anr_source"],
        app_version=row["app_version"] or "",
        app_build=row["app_build"] or "",
        device_model=row["device_model"] or "",
        device_os_version=row["device_os_version"] or "",
        distinct_id=row["distinct_id"],
        anonymous_id=row["anonymous_id"] or "",
        session_id=row["session_id"] or "",
        user_id=row["user_id"] or "",
        extras=extras if isinstance(extras, dict) else {},
        event_time=row["event_time"],
        received_at=row["received_at"],
    )


async def overview(pool: asyncpg.Pool, frm: datetime, to: datetime) -> StabilityOverview:
    from_date, to_date = inclusive_date_range(frm, to)
    to_exclusive = to_date.replace(hour=0, minute=0, second=0, microsecond=0)
    # inclusive end day: use next day exclusive
    from datetime import timedelta

    to_exclusive = to_exclusive + timedelta(days=1)

    async with pool.acquire() as conn:
        counts = await conn.fetch(
            """
            SELECT kind, COUNT(*)::bigint AS c
            FROM stability_events
            WHERE event_time >= $1 AND event_time < $2
            GROUP BY kind
            """,
            from_date,
            to_exclusive,
        )
        by_kind = {r["kind"]: int(r["c"]) for r in counts}
        issue_count = await conn.fetchval(
            """
            SELECT COUNT(*)::bigint FROM stability_issues
            WHERE last_seen_at >= $1 AND last_seen_at < $2
            """,
            from_date,
            to_exclusive,
        )
        affected = await conn.fetchval(
            """
            SELECT COUNT(DISTINCT user_id)::bigint FROM stability_events
            WHERE event_time >= $1 AND event_time < $2
              AND user_id IS NOT NULL AND user_id != ''
            """,
            from_date,
            to_exclusive,
        )
        trend_rows = await conn.fetch(
            """
            SELECT DATE(event_time AT TIME ZONE 'UTC') AS d,
                   kind,
                   COUNT(*)::bigint AS c
            FROM stability_events
            WHERE event_time >= $1 AND event_time < $2
            GROUP BY d, kind
            ORDER BY d
            """,
            from_date,
            to_exclusive,
        )

    trend_map: dict[str, dict[str, int]] = {}
    for r in trend_rows:
        day = r["d"].isoformat() if hasattr(r["d"], "isoformat") else str(r["d"])
        bucket = trend_map.setdefault(day, {"crash": 0, "error": 0, "anr": 0})
        bucket[r["kind"]] = int(r["c"])

    trend = [
        StabilityTrendPoint(
            date=day,
            crash=vals.get("crash", 0),
            error=vals.get("error", 0),
            anr=vals.get("anr", 0),
        )
        for day, vals in sorted(trend_map.items())
    ]

    return StabilityOverview(
        crash=by_kind.get("crash", 0),
        error=by_kind.get("error", 0),
        anr=by_kind.get("anr", 0),
        issue_count=int(issue_count or 0),
        affected_users=int(affected or 0),
        trend=trend,
    )


async def list_issues(
    pool: asyncpg.Pool,
    frm: datetime,
    to: datetime,
    kind: str = "",
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[StabilityIssueSummary], int]:
    from datetime import timedelta

    from_date, to_date = inclusive_date_range(frm, to)
    to_exclusive = to_date.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    kind = (kind or "").strip().lower()

    where = "WHERE last_seen_at >= $1 AND last_seen_at < $2"
    args: list[Any] = [from_date, to_exclusive]
    if kind in ("crash", "error", "anr"):
        where += f" AND kind = ${len(args) + 1}"
        args.append(kind)

    async with pool.acquire() as conn:
        total = await conn.fetchval(
            f"SELECT COUNT(*)::bigint FROM stability_issues {where}", *args
        )
        rows = await conn.fetch(
            f"""
            SELECT * FROM stability_issues
            {where}
            ORDER BY occurrence_count DESC, last_seen_at DESC
            LIMIT ${len(args) + 1} OFFSET ${len(args) + 2}
            """,
            *args,
            limit,
            offset,
        )
    return [_row_to_issue(r) for r in rows], int(total or 0)


async def get_issue(
    pool: asyncpg.Pool,
    fingerprint: str,
    limit: int = 50,
    offset: int = 0,
) -> StabilityIssueDetail | None:
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    async with pool.acquire() as conn:
        issue_row = await conn.fetchrow(
            "SELECT * FROM stability_issues WHERE fingerprint = $1", fingerprint
        )
        if not issue_row:
            return None
        total = await conn.fetchval(
            "SELECT COUNT(*)::bigint FROM stability_events WHERE fingerprint = $1",
            fingerprint,
        )
        rows = await conn.fetch(
            """
            SELECT * FROM stability_events
            WHERE fingerprint = $1
            ORDER BY event_time DESC
            LIMIT $2 OFFSET $3
            """,
            fingerprint,
            limit,
            offset,
        )
    return StabilityIssueDetail(
        issue=_row_to_issue(issue_row),
        events=[_row_to_event(r) for r in rows],
        total=int(total or 0),
    )
