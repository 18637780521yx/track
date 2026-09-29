from __future__ import annotations

import gzip
import json

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from app.db import get_pool
from app.models import IngestResponse
from app.services.parse import parse_ingest_events
from app.services.sync import ingest

router = APIRouter()


async def _read_body(request: Request) -> bytes:
    body = await request.body()
    if request.headers.get("content-encoding", "").lower() == "gzip":
        try:
            return gzip.decompress(body)
        except OSError as exc:
            raise ValueError("invalid gzip") from exc
    return body


@router.post("/track")
@router.post("/api/v1/track")
async def track_ingest(request: Request):
    try:
        body = await _read_body(request)
    except ValueError:
        return JSONResponse({"error": "invalid body"}, status_code=400)

    try:
        payload = json.loads(body.decode("utf-8") if body else "{}")
        events = parse_ingest_events(payload)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return JSONResponse({"error": "invalid json"}, status_code=400)

    try:
        stored, dropped = await ingest(get_pool(), events)
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=500)

    return IngestResponse(ok=True, total=len(events), stored=stored, dropped=dropped)
