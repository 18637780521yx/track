from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any

from app.models import EventFilter, TrackEvent

SAFE_JSON_KEY = re.compile(r"^[a-zA-Z0-9_.-]{1,64}$")

TIME_LAYOUTS = (
    "%Y-%m-%dT%H:%M:%S.%f%z",
    "%Y-%m-%dT%H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%S.%f",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
)


def parse_flexible_time(value: Any) -> datetime | None:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value), tz=timezone.utc)
    if isinstance(value, str):
        s = value.strip()
        if not s:
            return None
        try:
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except ValueError:
            pass
        for layout in TIME_LAYOUTS:
            try:
                dt = datetime.strptime(s, layout)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt.astimezone(timezone.utc)
            except ValueError:
                continue
        raise ValueError(f"invalid time {s!r}")
    raise ValueError("unsupported timestamp format")


def parse_ingest_events(payload: dict[str, Any]) -> list[TrackEvent]:
    raw_events = payload.get("events") or []
    events: list[TrackEvent] = []
    for i, item in enumerate(raw_events):
        if not isinstance(item, dict):
            raise ValueError(f"events[{i}] must be object")
        ts = None
        if "timestamp" in item:
            ts = parse_flexible_time(item.get("timestamp"))
        events.append(
            TrackEvent(
                event_id=str(item.get("event_id") or ""),
                name=str(item.get("name") or ""),
                properties=item.get("properties") or {},
                common_properties=item.get("common_properties") or {},
                distinct_id=item.get("distinct_id"),
                anonymous_id=str(item.get("anonymous_id") or ""),
                session_id=str(item.get("session_id") or ""),
                timestamp=ts,
            )
        )
    return events


def parse_range(from_str: str | None, to_str: str | None) -> tuple[datetime, datetime]:
    now = datetime.now(timezone.utc)
    to = now
    frm = now - timedelta(days=7)
    if to_str:
        try:
            to = datetime.fromisoformat(to_str.replace("Z", "+00:00")).astimezone(timezone.utc)
        except ValueError:
            pass
    if from_str:
        try:
            frm = datetime.fromisoformat(from_str.replace("Z", "+00:00")).astimezone(timezone.utc)
        except ValueError:
            pass
    return frm, to


def inclusive_date_range(frm: datetime, to: datetime) -> tuple[datetime, datetime]:
    f = frm.astimezone(timezone.utc)
    t = to.astimezone(timezone.utc)
    from_date = datetime(f.year, f.month, f.day, tzinfo=timezone.utc)
    to_date = datetime(t.year, t.month, t.day, tzinfo=timezone.utc)
    return from_date, to_date


def append_event_filters(
    filters: list[EventFilter] | None, start_idx: int
) -> tuple[str, list[Any], int]:
    if not filters:
        return "", [], start_idx
    next_idx = start_idx
    parts: list[str] = []
    args: list[Any] = []
    for f in filters:
        source = (f.source or "").strip()
        field = (f.field or "").strip()
        op = (f.op or "eq").strip().lower()
        value = (f.value or "").strip()
        if not field or not value or not SAFE_JSON_KEY.match(field):
            continue
        if source in ("properties", "prop", "event"):
            col = "properties"
        elif source in ("common", "common_properties", ""):
            col = "common_properties"
        else:
            continue
        expr = f"COALESCE({col}->>'{field}', '')"
        if op in ("eq", "equal", "="):
            parts.append(f"{expr} = ${next_idx}")
            args.append(value)
            next_idx += 1
        elif op in ("neq", "not_equal", "!="):
            parts.append(f"{expr} <> ${next_idx}")
            args.append(value)
            next_idx += 1
        elif op in ("contains", "like"):
            parts.append(f"{expr} ILIKE ${next_idx}")
            args.append(f"%{value}%")
            next_idx += 1
    if not parts:
        return "", [], next_idx
    return " AND " + " AND ".join(parts), args, next_idx
