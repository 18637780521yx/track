#!/usr/bin/env python3
import os
import time
from pathlib import Path

import paramiko

HOST = "10.10.10.132"
REMOTE = "/home/mobile/track-deploy"
LOCAL_PURGE = Path(__file__).resolve().parent / "_purge_once.py"

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username="mobile", password=os.environ["TRACK_SSH_PASSWORD"], timeout=20)


def run(cmd, timeout=900):
    print(f"\n>>> {cmd[:160]}")
    _, o, _ = c.exec_command(cmd, timeout=timeout, get_pty=True)
    out = o.read().decode("utf-8", errors="replace")
    code = o.channel.recv_exit_status()
    print(out[-2500:] if len(out) > 2500 else out)
    print(f"exit={code}")
    return code, out


sftp = c.open_sftp()
sftp.put(str(LOCAL_PURGE), f"{REMOTE}/_purge_once.py")
sftp.close()

code, out = run(
    "sudo docker exec track-prod-server-1 ls /app/app/services/retention.py; "
    "sudo docker exec track-prod-server-1 python -c 'from app.config import settings; print(settings.retention_days)'"
)
if "No such file" in out or "Traceback" in out:
    run(
        "cd /home/mobile/track-deploy && "
        "sudo docker compose --env-file .env.prod -p track-prod build --no-cache server 2>&1 | tail -20"
    )
    run(
        "cd /home/mobile/track-deploy && "
        "sudo docker compose --env-file .env.prod -p track-prod up -d server"
    )
    time.sleep(5)

run("sudo docker cp /home/mobile/track-deploy/_purge_once.py track-test-server-1:/tmp/purge_once.py")
run("sudo docker exec track-test-server-1 python /tmp/purge_once.py")
run("sudo docker cp /home/mobile/track-deploy/_purge_once.py track-prod-server-1:/tmp/purge_once.py")
run("sudo docker exec track-prod-server-1 python /tmp/purge_once.py")

time.sleep(18)
run("sudo docker logs --tail 20 track-test-server-1 2>&1")
c.close()
