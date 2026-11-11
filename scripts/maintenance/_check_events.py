#!/usr/bin/env python3
import os
import paramiko

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("10.10.10.132", username="mobile", password=os.environ["TRACK_SSH_PASSWORD"], timeout=15)

cmds = [
    # DB counts
    "sudo docker exec track-test-postgres-1 psql -U track -d track -c \"SELECT COUNT(*) AS events FROM events; SELECT COUNT(*) AS users FROM users; SELECT name, COUNT(*) FROM events GROUP BY name ORDER BY 2 DESC LIMIT 20;\"",
    # recent server logs
    "sudo docker logs --tail 80 track-test-server-1 2>&1",
    # health + overview via nginx
    "curl -sS http://127.0.0.1:18765/health; echo; curl -sS 'http://127.0.0.1:18765/api/v1/overview?from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z'; echo",
    # try post a test event
    """curl -sS -X POST http://127.0.0.1:18765/track -H 'Content-Type: application/json' -d '{"events":[{"event_id":"manual-test-001","name":"app_open","anonymous_id":"diag","session_id":"diag-s1","timestamp":"2026-11-09T09:20:00Z","properties":{},"common_properties":{}}]}'; echo""",
]

for cmd in cmds:
    print(f"\n>>> {cmd[:120]}")
    _, o, _ = c.exec_command(cmd, timeout=60, get_pty=True)
    print(o.read().decode("utf-8", errors="replace")[-4000:])
    print("exit", o.channel.recv_exit_status())

c.close()
