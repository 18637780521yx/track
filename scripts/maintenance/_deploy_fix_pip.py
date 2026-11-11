#!/usr/bin/env python3
"""Patch Dockerfile mirror + rebuild only."""
import os
import paramiko

HOST = "10.10.10.132"
USER = "mobile"
PASSWORD = os.environ["TRACK_SSH_PASSWORD"]
REMOTE_DIR = "/home/mobile/track-deploy"

DOCKERFILE = """FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple \\
    --trusted-host pypi.tuna.tsinghua.edu.cn -r requirements.txt

COPY app ./app
COPY migrations ./migrations

ENV ADDR=:8080
ENV DATABASE_URL=postgres://track:track@postgres:5432/track?sslmode=disable

EXPOSE 8080
CMD ["python", "-m", "app.main"]
"""


def run(client, cmd, timeout=900):
    print(f"\n>>> {cmd[:120]}...")
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout, get_pty=True)
    out = stdout.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    # print last 40 lines only
    lines = out.splitlines()
    for line in lines[-40:]:
        print(line)
    print(f"exit={code}")
    return code, out


def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASSWORD, timeout=20)

    sftp = client.open_sftp()
    with sftp.file(f"{REMOTE_DIR}/track-server-py/Dockerfile", "w") as f:
        f.write(DOCKERFILE)
    sftp.close()
    print("Dockerfile patched")

    code, _ = run(
        client,
        f"cd {REMOTE_DIR} && sudo docker compose up -d --build",
        timeout=900,
    )
    if code != 0:
        raise SystemExit(code)

    import time

    time.sleep(4)
    run(client, f"sudo docker compose -f {REMOTE_DIR}/docker-compose.yml ps")
    run(
        client,
        "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18765/ ; echo; "
        "curl -sS 'http://127.0.0.1:18765/api/v1/overview?from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z' | head -c 300; echo",
    )
    print("\nREADY: http://10.10.10.132:18765/")
    client.close()


if __name__ == "__main__":
    main()
