#!/usr/bin/env python3
import os
import time
from pathlib import Path
import paramiko

HOST = "10.10.10.132"
REMOTE = "/home/mobile/track-deploy"
LOCAL = str(Path(__file__).resolve().parents[2] / "deploy" / "nginx.conf")

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username="mobile", password=os.environ["TRACK_SSH_PASSWORD"], timeout=15)
sftp = c.open_sftp()
sftp.put(LOCAL, f"{REMOTE}/nginx.conf")
sftp.close()
print("uploaded nginx.conf")


def run(cmd, timeout=120):
    print(f"\n>>> {cmd[:140]}")
    _, o, _ = c.exec_command(cmd, timeout=timeout, get_pty=True)
    out = o.read().decode("utf-8", errors="replace")
    print(out[-2500:] if len(out) > 2500 else out)
    print("exit", o.channel.recv_exit_status())
    return out


# recreate web containers to remount nginx.conf
for env, proj in ((".env.test", "track-test"), (".env.prod", "track-prod")):
    run(f"cd {REMOTE} && sudo docker compose --env-file {env} -p {proj} up -d --force-recreate web")

time.sleep(2)
run(
    """curl -sS -o /tmp/track_post_out.txt -w '%{http_code}' -X POST http://127.0.0.1:18765/track """
    """-H 'Content-Type: application/json' """
    """-d '{"events":[{"event_id":"manual-test-002","name":"app_open","anonymous_id":"diag","session_id":"diag-s2","timestamp":"2026-11-09T09:24:00.000Z","properties":{},"common_properties":{}}]}'; """
    """echo; cat /tmp/track_post_out.txt; echo; """
    """curl -sS http://127.0.0.1:18765/health; echo; """
    """sudo docker exec track-test-postgres-1 psql -U track -d track -c 'SELECT COUNT(*) FROM events; SELECT name, session_id FROM events ORDER BY id DESC LIMIT 5;'"""
)
c.close()
