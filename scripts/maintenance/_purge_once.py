import asyncio

from app.db import close_pool, get_pool, init_pool
from app.services.retention import purge_expired, summarize


async def main() -> None:
    await init_pool()
    async with get_pool().acquire() as conn:
        deleted = await purge_expired(conn)
        print("purged", summarize(deleted) or "nothing")
    await close_pool()


asyncio.run(main())
