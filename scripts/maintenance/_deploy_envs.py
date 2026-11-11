#!/usr/bin/env python3
"""Deploy track-test (:18765) + track-prod (:28643) on 10.10.10.132."""
from __future__ import annotations
import os

import time
from pathlib import Path

import paramiko

HOST = "10.10.10.132"
USER = "mobile"
PASSWORD = os.environ["TRACK_SSH_PASSWORD"]
REMOTE = "/home/mobile/track-deploy"
ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "deploy"


def run(client: paramiko.SSHClient, cmd: str, timeout: int = 900) -> tuple[int, str]:
    print(f"\n>>> {cmd[:160]}")
    _, stdout, _ = client.exec_command(cmd, timeout=timeout, get_pty=True)
    out = stdout.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    for line in out.splitlines()[-30:]:
        print(line)
    print(f"exit={code}")
    return code, out


def main() -> None:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    sftp = client.open_sftp()

    for name in (
        "docker-compose.yml",
        "nginx.conf",
        ".env.test",
        ".env.prod",
        "README.md",
    ):
        local = DEPLOY / name
        remote = f"{REMOTE}/{name}"
        print(f"put {name}")
        sftp.put(str(local), remote)

    sftp.close()

    # tear down old single stack (volume kept under old name; test starts fresh named volume)
    run(
        client,
        f"cd {REMOTE} && sudo docker compose -p track-deploy down --remove-orphans 2>/dev/null; true",
    )

    # ensure image built once via test, then prod reuses same image tag if built in place
    code, _ = run(
        client,
        f"cd {REMOTE} && sudo docker compose --env-file .env.test -p track-test up -d --build",
        timeout=900,
    )
    if code != 0:
        raise SystemExit("test stack failed")

    code, _ = run(
        client,
        f"cd {REMOTE} && sudo docker compose --env-file .env.prod -p track-prod up -d --build",
        timeout=900,
    )
    if code != 0:
        raise SystemExit("prod stack failed")

    time.sleep(5)
    run(client, "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'track-|NAMES'")
    run(
        client,
        "echo TEST:; curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18765/; echo; "
        "curl -sS 'http://127.0.0.1:18765/api/v1/overview?from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z'; echo; "
        "echo PROD:; curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:28643/; echo; "
        "curl -sS 'http://127.0.0.1:28643/api/v1/overview?from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z'; echo",
    )
    print("\nTEST console: http://10.10.10.132:18765/")
    print("PROD console: http://10.10.10.132:28643/")
    client.close()


if __name__ == "__main__":
    main()
