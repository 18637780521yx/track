#!/usr/bin/env python3
import os
import paramiko

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("10.10.10.132", username="mobile", password=os.environ["TRACK_SSH_PASSWORD"], timeout=20)

cmds = [
    "sudo docker exec track-test-server-1 ls -la /app/app/services/retention.py",
    "sudo docker exec track-test-server-1 head -5 /app/app/services/retention.py",
    "sudo docker exec track-test-server-1 python -c \"from app.config import settings; print(settings.retention_days)\"",
    # force rebuild no cache
    "cd /home/mobile/track-deploy && sudo docker compose --env-file .env.test -p track-test build --no-cache server 2>&1 | tail -40",
    "cd /home/mobile/track-deploy && sudo docker compose --env-file .env.test -p track-test up -d server",
    "cd /home/mobile/track-deploy && sudo docker compose --env-file .env.prod -p track-prod build server 2>&1 | tail -20",
    "cd /home/mobile/track-deploy && sudo docker compose --env-file .env.prod -p track-prod up -d server",
]

for cmd in cmds:
    print(f"\n>>> {cmd[:120]}")
    _, o, _ = c.exec_command(cmd, timeout=900, get_pty=True)
    out = o.read().decode("utf-8", errors="replace")
    code = o.channel.recv_exit_status()
    print(out[-3000:] if len(out) > 3000 else out)
    print(f"exit={code}")

c.close()
