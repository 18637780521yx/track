#!/usr/bin/env python3
"""Probe nginx + disk + free ports."""
import os
import paramiko

HOST = "10.10.10.132"
USER = "mobile"
PASSWORD = os.environ["TRACK_SSH_PASSWORD"]

cmds = [
    "sudo nginx -t 2>&1; systemctl is-active nginx 2>&1; ss -lntp | grep -E ':80|:443|:8080' || true",
    "df -h / /home 2>/dev/null; free -h | head -2",
    "ls -la /etc/nginx/sites-enabled/; sudo cat /etc/nginx/sites-enabled/default | head -80",
    "ls /home/mobile; which rsync scp tar",
    "sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | head -20",
]

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(HOST, username=USER, password=PASSWORD, timeout=15)
for c in cmds:
    print(f"\n>>> {c}")
    stdin, stdout, stderr = client.exec_command(c, timeout=60)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    if out:
        print(out.rstrip())
    if err:
        print("ERR:", err.rstrip())
client.close()
