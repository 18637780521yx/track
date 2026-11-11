#!/usr/bin/env python3
import os
import paramiko

HOST = "10.10.10.132"
USER = "mobile"
PASSWORD = os.environ["TRACK_SSH_PASSWORD"]

cmds = [
    "ls -la /etc/nginx/conf.d/; sudo head -40 /etc/nginx/conf.d/staging.conf",
    "ss -lntp | head -40",
    "ls /var/www/lq_mom_be | head -20; ls /home/mobile -la",
    "sudo cat /etc/nginx/nginx.conf | head -60",
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
