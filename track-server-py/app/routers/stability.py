from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from app.db import get_pool
from app.services import stability
from app.services.parse import parse_range

router = APIRouter(prefix="/api/v1/stability")


@router.get("/overview")
async def overview(request: Request):
    frm, to = parse_range(request.query_params.get("from"), request.query_params.get("to"))
    try:
        return await stability.overview(get_pool(), frm, to)
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/issues")
async def list_issues(
    request: Request,
    kind: str = "",
    limit: int = 50,
    offset: int = 0,
):
    frm, to = parse_range(request.query_params.get("from"), request.query_params.get("to"))
    try:
        items, total = await stability.list_issues(
            get_pool(), frm, to, kind=kind, limit=limit, offset=offset
        )
        return {"items": items, "total": total}
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)


@router.get("/issues/{fingerprint}")
async def get_issue(fingerprint: str, limit: int = 50, offset: int = 0):
    try:
        detail = await stability.get_issue(get_pool(), fingerprint, limit=limit, offset=offset)
        if detail is None:
            return JSONResponse({"error": "issue not found"}, status_code=404)
        return detail
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)
