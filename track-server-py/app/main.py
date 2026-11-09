from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.db import close_pool, get_pool, init_pool
from app.routers import analytics, ingest, stability


async def _app_log_ttl_loop(stop: asyncio.Event) -> None:
    """每分钟清掉超过 2 小时的 app_logs。"""
    from app.services.applog import purge_expired_logs

    while not stop.is_set():
        try:
            pool = get_pool()
            async with pool.acquire() as conn:
                deleted = await purge_expired_logs(conn)
                if deleted:
                    print(f"[applog] purged {deleted} expired rows", flush=True)
        except Exception as exc:
            print(f"[applog] purge failed: {exc}", flush=True)
        try:
            await asyncio.wait_for(stop.wait(), timeout=60)
        except asyncio.TimeoutError:
            pass


async def _retention_loop(stop: asyncio.Event) -> None:
    """每小时清掉超过保留期的埋点 / 报告衍生数据（默认 7 天）。"""
    from app.services.retention import purge_expired, summarize

    # 启动后稍等再扫，避免和迁移抢连接
    try:
        await asyncio.wait_for(stop.wait(), timeout=15)
        return
    except asyncio.TimeoutError:
        pass

    while not stop.is_set():
        try:
            pool = get_pool()
            async with pool.acquire() as conn:
                deleted = await purge_expired(conn)
                summary = summarize(deleted)
                if summary:
                    print(
                        f"[retention] purged ({settings.retention_days}d): {summary}",
                        flush=True,
                    )
        except Exception as exc:
            print(f"[retention] purge failed: {exc}", flush=True)
        try:
            await asyncio.wait_for(stop.wait(), timeout=3600)
        except asyncio.TimeoutError:
            pass


@asynccontextmanager
async def lifespan(_app: FastAPI):
    await init_pool()
    stop = asyncio.Event()
    tasks = [
        asyncio.create_task(_app_log_ttl_loop(stop)),
        asyncio.create_task(_retention_loop(stop)),
    ]
    yield
    stop.set()
    await asyncio.gather(*tasks, return_exceptions=True)
    await close_pool()


app = FastAPI(title="track-server-py", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Content-Encoding"],
)
app.include_router(ingest.router)
app.include_router(analytics.router)
app.include_router(stability.router)


@app.get("/health")
async def health():
    return {"ok": True}


def main() -> None:
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host=settings.host,
        port=settings.port,
        reload=False,
    )


if __name__ == "__main__":
    main()
