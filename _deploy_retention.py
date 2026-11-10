#!/usr/bin/env python3
"""Upload retention changes and rebuild test+prod server images."""
from __future__ import annotations
import os

import time
from pathlib import Path

import paramiko

HOST = "10.10.10.132"
USER = "mobile"
PASSWORD = os.environ["TRACK_SSH_PASSWORD"]
REMOTE = "/home/mobile/track-deploy"
ROOT = Path(__file__).resolve().parent
SERVER = ROOT / "track-server-py"
DEPLOY = ROOT / "deploy"

UPLOADS = [
    (SERVER / "app" / "config.py", f"{REMOTE}/track-server-py/app/config.py"),
    (SERVER / "app" / "main.py", f"{REMOTE}/track-server-py/app/main.py"),
    (SERVER / "app" / "services" / "sync.py", f"{REMOTE}/track-server-py/app/services/sync.py"),
    (SERVER / "app" / "services" / "retention.py", f"{REMOTE}/track-server-py/app/services/retention.py"),
    (DEPLOY / "docker-compose.yml", f"{REMOTE}/docker-compose.yml"),
    (DEPLOY / ".env.test", f"{REMOTE}/.env.test"),
    (DEPLOY / ".env.prod", f"{REMOTE}/.env.prod"),
]


def run(client, cmd, timeout=900):
    print(f"\n>>> {cmd[:160]}")
    _, stdout, _ = client.exec_command(cmd, timeout=timeout, get_pty=True)
    out = stdout.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    for line in out.splitlines()[-30:]:
        print(line)
    print(f"exit={code}")
    return code


def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    sftp = client.open_sftp()
    for local, remote in UPLOADS:
        print(f"put {local.name} -> {remote}")
        sftp.put(str(local), remote)
    sftp.close()

    for env, proj in ((".env.test", "track-test"), (".env.prod", "track-prod")):
        code = run(
            client,
            f"cd {REMOTE} && sudo docker compose --env-file {env} -p {proj} up -d --build server",
            timeout=900,
        )
        if code != 0:
            raise SystemExit(f"{proj} rebuild failed")

    time.sleep(12)
    run(
        client,
        "sudo docker logs --tail 40 track-test-server-1 2>&1; echo ====; "
        "sudo docker logs --tail 20 track-prod-server-1 2>&1",
    )
    # 立刻跑一轮清理（不等整点）
    py = (
        "import asyncio;"
        "from app.db import init_pool,get_pool,close_pool;"
        "from app.services.retention import purge_expired,summarize;"
        "async def m():\n"
        " await init_pool();\n"
        " async with get_pool().acquire() as c:\n"
        "  d=await purge_expired(c); print('purged', summarize(d) or 'nothing');\n"
        " await close_pool();\n"
        "asyncio.run(m())"
    )
    run(client, f"sudo docker exec track-test-server-1 python -c \"{py}\"")
    print("done")
    client.close()


if __name__ == "__main__":
    main()
