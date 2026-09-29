from __future__ import annotations

import json
from typing import Optional

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from app.db import get_pool
from app.models import EventFilter, FunnelRequest
from app.services import analytics
from app.services.parse import parse_range

router = APIRouter(prefix="/api/v1")


def _filters_from_query(raw: Optional[str]):
    if not raw or not raw.strip():
        return None
    try:
        data = json.loads(raw)
        return [EventFilter.model_validate(x) for x in data]
    except Exception:
        return None


@router.get("/overview")
async def overview(request: Request):
    frm, to = parse_range(request.query_params.get("from"), request.query_params.get("to"))
    try:
        stats = await analytics.overview(get_pool(), frm, to)
        return stats
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/events/names")
async def event_names(q: str = ""):
    try:
        items = await analytics.event_names(get_pool(), q)
        return {"items": items}
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/events/trend")
async def event_trend(
    request: Request,
    event: str = "",
    unit: str = "day",
    filters: Optional[str] = None,
):
    frm, to = parse_range(request.query_params.get("from"), request.query_params.get("to"))
    try:
        items = await analytics.event_trend(
            get_pool(), event, frm, to, unit, _filters_from_query(filters)
        )
        return {"items": items}
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/events/property-values")
async def property_values(
    field: str = "",
    source: str = "common",
    event: str = "",
    limit: int = 50,
):
    try:
        items = await analytics.property_values(get_pool(), source, field, event, limit)
        return {"items": items}
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/events")
async def list_events(
    request: Request,
    event: str = "",
    limit: int = 50,
    offset: int = 0,
    filters: Optional[str] = None,
):
    frm, to = parse_range(request.query_params.get("from"), request.query_params.get("to"))
    try:
        items, total = await analytics.list_events(
            get_pool(), event, frm, to, limit, offset, _filters_from_query(filters)
        )
        return {"items": items, "total": total}
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.post("/funnel")
async def funnel(body: FunnelRequest):
    frm, to = parse_range(body.from_, body.to)
    try:
        result = await analytics.funnel(get_pool(), body.steps, frm, to, body.window_hours)
        return result
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/retention")
async def retention(
    request: Request,
    cohort_event: str = "app_start",
    return_event: str = "",
    days: int = 7,
):
    frm, to = parse_range(request.query_params.get("from"), request.query_params.get("to"))
    if not return_event:
        return_event = cohort_event
    try:
        result = await analytics.retention(
            get_pool(), cohort_event, return_event, frm, to, days
        )
        return result
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/users")
async def list_users(q: str = "", limit: int = 50, offset: int = 0):
    try:
        items, total = await analytics.list_users(get_pool(), q, limit, offset)
        return {"items": items, "total": total}
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/users/{user_id}/events")
async def list_user_events(
    user_id: str,
    request: Request,
    limit: int = 500,
    offset: int = 0,
):
    frm, to = parse_range(request.query_params.get("from"), request.query_params.get("to"))
    try:
        result = await analytics.list_user_events(get_pool(), user_id, frm, to, limit, offset)
        if result is None:
            return JSONResponse({"error": "user not found"}, status_code=404)
        items, total = result
        return {"items": items, "total": total}
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/users/{user_id}")
async def get_user(user_id: str):
    try:
        user = await analytics.get_user(get_pool(), user_id)
        if user is None:
            return JSONResponse({"error": "user not found"}, status_code=404)
        return user
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)
