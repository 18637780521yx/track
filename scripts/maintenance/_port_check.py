#!/usr/bin/env python3
import os
import paramiko

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("10.10.10.132", username="mobile", password=os.environ["TRACK_SSH_PASSWORD"], timeout=15)
_, o, _ = c.exec_command("ss -lnt")
print(o.read().decode("utf-8", errors="replace"))
c.close()
