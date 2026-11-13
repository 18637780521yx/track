from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from typing import Any

import asyncpg

from app.models import (
    EventFilter,
    EventRecord,
    StabilityEventRecord,
    StabilityIssueDetail,
    StabilityIssueSummary,
    StabilityOverview,
    StabilityTrendPoint,
    TrackEvent,
)
from app.services.parse import append_event_filters, inclusive_date_range
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


def event_name_for_kind(kind: str) -> str:
    for name, k in STABILITY_EVENT_KINDS.items():
        if k == kind:
            return name
    return kind


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

    extras.pop("app_package", None)
    if package := prop_string(common, "app_package"):
        extras["app_package"] = package

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


# Older stability events did not store the package. A session is usable for
# attribution only when its recorded events identify a single app.
_STABILITY_PACKAGE = """COALESCE(NULLIF(extras->>'app_package', ''), (
    SELECT MIN(e.common_properties->>'app_package')
    FROM events e
    WHERE e.session_id = stability_events.session_id
      AND stability_events.session_id NOT IN ('', 'unknown')
    HAVING COUNT(DISTINCT NULLIF(e.common_properties->>'app_package', '')) = 1
))"""


def _scoped_issues(where: str) -> str:
    return f"""
        SELECT e.fingerprint, (ARRAY_AGG(e.kind ORDER BY event_time DESC))[1] AS kind,
               (ARRAY_AGG(e.exception_type ORDER BY event_time DESC))[1] AS exception_type,
               (ARRAY_AGG(e.message ORDER BY event_time DESC))[1] AS sample_message,
               (ARRAY_AGG(e.stack ORDER BY event_time DESC))[1] AS sample_stack,
               COUNT(*) AS occurrence_count, COUNT(DISTINCT NULLIF(e.user_id, '')) AS user_count,
               MIN(event_time) AS first_seen_at, MAX(event_time) AS last_seen_at,
               i.status
        FROM (SELECT * FROM stability_events WHERE {where}) e
        JOIN stability_issues i USING (fingerprint)
        GROUP BY e.fingerprint, i.status
    """


async def overview(pool: asyncpg.Pool, frm: datetime, to: datetime, app_package: str = "") -> StabilityOverview:
    from_date, to_date = inclusive_date_range(frm, to)
    to_exclusive = to_date.replace(hour=0, minute=0, second=0, microsecond=0)
    # inclusive end day: use next day exclusive
    from datetime import timedelta

    to_exclusive = to_exclusive + timedelta(days=1)

    args: list[Any] = [from_date, to_exclusive]
    scope = ""
    if app_package:
        args.append(app_package)
        scope = f"AND {_STABILITY_PACKAGE} = $3"

    async with pool.acquire() as conn:
        counts = await conn.fetch(
            f"""
            SELECT kind, COUNT(*)::bigint AS c
            FROM stability_events
            WHERE event_time >= $1 AND event_time < $2 {scope}
            GROUP BY kind
            """,
            *args,
        )
        by_kind = {r["kind"]: int(r["c"]) for r in counts}
        if app_package:
            issue_count = await conn.fetchval(
                f"""SELECT COUNT(DISTINCT fingerprint) FROM stability_events
                    WHERE event_time >= $1 AND event_time < $2 {scope}""", *args
            )
        else:
            issue_count = await conn.fetchval(
                """SELECT COUNT(*) FROM stability_issues
                   WHERE last_seen_at >= $1 AND last_seen_at < $2""", *args
            )
        affected = await conn.fetchval(
            f"""
            SELECT COUNT(DISTINCT user_id)::bigint FROM stability_events
            WHERE event_time >= $1 AND event_time < $2 {scope}
              AND user_id IS NOT NULL AND user_id != ''
            """,
            *args,
        )
        trend_rows = await conn.fetch(
            f"""
            SELECT DATE(event_time AT TIME ZONE 'UTC') AS d,
                   kind,
                   COUNT(*)::bigint AS c
            FROM stability_events
            WHERE event_time >= $1 AND event_time < $2 {scope}
            GROUP BY d, kind
            ORDER BY d
            """,
            *args,
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
    app_package: str = "",
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

    if app_package:
        where = where.replace("last_seen_at", "event_time")
        where += f" AND {_STABILITY_PACKAGE} = ${len(args) + 1}"
        args.append(app_package)
        source = f"({_scoped_issues(where.removeprefix('WHERE '))}) issues"
        where = ""
    else:
        source = "stability_issues"

    async with pool.acquire() as conn:
        total = await conn.fetchval(
            f"SELECT COUNT(*)::bigint FROM {source} {where}", *args
        )
        rows = await conn.fetch(
            f"""
            SELECT * FROM {source}
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
    app_package: str = "",
) -> StabilityIssueDetail | None:
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    args: list[Any] = [fingerprint]
    where = "fingerprint = $1"
    if app_package:
        where += f" AND {_STABILITY_PACKAGE} = $2"
        args.append(app_package)
        issue_query = _scoped_issues(where)
    else:
        issue_query = "SELECT * FROM stability_issues WHERE fingerprint = $1"
    async with pool.acquire() as conn:
        issue_row = await conn.fetchrow(issue_query, *args)
        if not issue_row:
            return None
        total = await conn.fetchval(
            f"SELECT COUNT(*)::bigint FROM stability_events WHERE {where}",
            *args,
        )
        rows = await conn.fetch(
            f"""
            SELECT * FROM stability_events
            WHERE {where}
            ORDER BY event_time DESC
            LIMIT ${len(args) + 1} OFFSET ${len(args) + 2}
            """,
            *args,
            limit,
            offset,
        )
    return StabilityIssueDetail(
        issue=_row_to_issue(issue_row),
        events=[_row_to_event(r) for r in rows],
        total=int(total or 0),
    )


def _stability_row_to_event_record(row: asyncpg.Record) -> EventRecord:
    """把 stability_events 行还原成会话报告 / 事件列表用的 EventRecord。"""
    extras = row["extras"]
    if isinstance(extras, str):
        try:
            extras = json.loads(extras)
        except json.JSONDecodeError:
            extras = {}
    if not isinstance(extras, dict):
        extras = {}

    props: dict[str, Any] = {**extras}
    props["exception_type"] = row["exception_type"] or props.get("exception_type") or "Unknown"
    if row["message"]:
        props.setdefault("message", row["message"])
        props.setdefault("exception", row["message"])
    if row["stack"]:
        props.setdefault("stack", row["stack"])
    if row["thread"]:
        props.setdefault("thread", row["thread"])
    props["is_fatal"] = bool(row["is_fatal"])
    if row["fingerprint"]:
        props.setdefault("fingerprint", row["fingerprint"])
    if row["blocked_ms"] is not None:
        props.setdefault("blocked_ms", row["blocked_ms"])
    if row["anr_source"]:
        props.setdefault("anr_source", row["anr_source"])

    common: dict[str, Any] = {}
    if row["app_package"]:
        common["app_package"] = row["app_package"]
    props.pop("app_package", None)
    if row["app_version"]:
        common["app_version"] = row["app_version"]
    if row["app_build"]:
        common["app_build"] = row["app_build"]
    if row["device_model"]:
        common["device_model"] = row["device_model"]
    if row["device_os_version"]:
        common["device_os_version"] = row["device_os_version"]

    return EventRecord(
        event_id=row["event_id"],
        name=event_name_for_kind(row["kind"]),
        properties=props,
        common_properties=common,
        distinct_id=row["distinct_id"],
        anonymous_id=row["anonymous_id"] or "",
        session_id=row["session_id"] or "",
        event_time=row["event_time"],
        received_at=row["received_at"],
    )


async def list_stability_as_events(
    pool: asyncpg.Pool,
    event_name: str,
    frm: datetime,
    to: datetime,
    limit: int,
    offset: int,
    filters: list[EventFilter] | None,
    app_package: str = "",
) -> tuple[list[EventRecord], int]:
    """按埋点名从 stability_events 读出，供会话报告 /events 列表使用。

    ingest 时 crash/error/anr 只进 stability 表、不进 events；这里做回读映射。
    """
    if limit <= 0:
        limit = 50
    if limit > 200:
        limit = 200
    kind = kind_for_event(event_name)

    # 用子查询拼出 properties / common_properties，复用通用 filter 语法
    args: list[Any] = [frm, to, kind]
    scope = ""
    if app_package:
        args.append(app_package)
        scope = f"AND {_STABILITY_PACKAGE} = $4"
    base = f"""
        SELECT * FROM (
            SELECT
                event_id,
                kind,
                fingerprint,
                exception_type,
                message,
                stack,
                thread,
                is_fatal,
                blocked_ms,
                anr_source,
                app_version,
                app_build,
                device_model,
                device_os_version,
                distinct_id,
                anonymous_id,
                session_id,
                extras,
                {_STABILITY_PACKAGE} AS app_package,
                event_time,
                received_at,
                (
                    COALESCE(extras, '{{}}'::jsonb)
                    || jsonb_strip_nulls(jsonb_build_object(
                        'exception_type', NULLIF(exception_type, ''),
                        'message', NULLIF(message, ''),
                        'exception', NULLIF(message, ''),
                        'stack', NULLIF(stack, ''),
                        'thread', NULLIF(thread, ''),
                        'is_fatal', is_fatal,
                        'fingerprint', NULLIF(fingerprint, ''),
                        'blocked_ms', blocked_ms,
                        'anr_source', NULLIF(anr_source, '')
                    ))
                ) AS properties,
                jsonb_strip_nulls(jsonb_build_object(
                    'app_package', {_STABILITY_PACKAGE},
                    'app_version', NULLIF(app_version, ''),
                    'app_build', NULLIF(app_build, ''),
                    'device_model', NULLIF(device_model, ''),
                    'device_os_version', NULLIF(device_os_version, '')
                )) AS common_properties
            FROM stability_events
            WHERE event_time >= $1 AND event_time < $2 AND kind = $3 {scope}
        ) AS events
        WHERE TRUE
    """
    filter_sql, filter_args, next_idx = append_event_filters(filters, len(args) + 1)
    where = base + filter_sql
    args.extend(filter_args)

    async with pool.acquire() as conn:
        total = int(await conn.fetchval(f"SELECT COUNT(*) FROM ({where}) q", *args) or 0)
        rows = await conn.fetch(
            f"""
            {where}
            ORDER BY event_time DESC
            LIMIT ${next_idx} OFFSET ${next_idx + 1}
            """,
            *args,
            limit,
            offset,
        )
    return [_stability_row_to_event_record(r) for r in rows], total
