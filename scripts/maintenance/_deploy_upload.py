#!/usr/bin/env python3
"""Pack + upload + docker compose deploy track to 10.10.10.132:18765."""
from __future__ import annotations
import os

import io
import tarfile
import time
from pathlib import Path

import paramiko

HOST = "10.10.10.132"
USER = "mobile"
PASSWORD = os.environ["TRACK_SSH_PASSWORD"]
REMOTE_DIR = "/home/mobile/track-deploy"
PORT = 18765

ROOT = Path(__file__).resolve().parents[2]
SERVER_SRC = ROOT / "track-server-py"
CONSOLE_DIST = ROOT / "track-console" / "dist"
DEPLOY = ROOT / "deploy"

SKIP_DIRS = {".venv", "venv", "__pycache__", ".git", ".pytest_cache", "node_modules"}
SKIP_SUFFIXES = {".pyc", ".pyo"}


def should_skip(path: Path) -> bool:
    parts = set(path.parts)
    if parts & SKIP_DIRS:
        return True
    if path.suffix in SKIP_SUFFIXES:
        return True
    return False


def make_tarball(out_path: Path) -> None:
    with tarfile.open(out_path, mode="w:gz") as tar:
        for name in ("docker-compose.yml", "nginx.conf"):
            p = DEPLOY / name
            tar.add(p, arcname=name)

        for p in SERVER_SRC.rglob("*"):
            if not p.is_file() or should_skip(p.relative_to(SERVER_SRC)):
                continue
            rel = p.relative_to(SERVER_SRC)
            tar.add(p, arcname=f"track-server-py/{rel.as_posix()}")

        for p in CONSOLE_DIST.rglob("*"):
            if not p.is_file():
                continue
            # copy to temp then add — avoid Windows file-lock / sparse read issues
            data = p.read_bytes()
            info = tarfile.TarInfo(name=f"track-console-dist/{p.relative_to(CONSOLE_DIST).as_posix()}")
            info.size = len(data)
            info.mtime = int(p.stat().st_mtime)
            tar.addfile(info, io.BytesIO(data))


def run(client: paramiko.SSHClient, cmd: str, timeout: int = 600) -> tuple[int, str, str]:
    print(f"\n>>> {cmd}")
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout, get_pty=True)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    if out.strip():
        print(out.rstrip())
    if err.strip():
        print("ERR:", err.rstrip())
    print(f"exit={code}")
    return code, out, err


def main() -> None:
    assert CONSOLE_DIST.joinpath("index.html").is_file(), "console dist missing; build first"
    assert (SERVER_SRC / "Dockerfile").is_file()
    assert (DEPLOY / "docker-compose.yml").is_file()

    local_tar = Path(__file__).resolve().parent / "artifacts" / "_track_bundle.tgz"
    local_tar.parent.mkdir(parents=True, exist_ok=True)
    print("packing…")
    if local_tar.exists():
        local_tar.unlink()
    make_tarball(local_tar)
    print(f"tarball size: {local_tar.stat().st_size / 1024 / 1024:.2f} MB")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    print("ssh ok")

    run(client, f"mkdir -p {REMOTE_DIR}")

    sftp = client.open_sftp()
    remote_tar = f"{REMOTE_DIR}/track-bundle.tgz"
    print(f"uploading -> {remote_tar}")
    sftp.put(str(local_tar), remote_tar)
    sftp.close()
    print("upload done")

    run(client, f"cd {REMOTE_DIR} && tar -xzf track-bundle.tgz && ls -la")
    # build + up (sudo for docker sock)
    code, out, err = run(
        client,
        f"cd {REMOTE_DIR} && sudo docker compose down --remove-orphans 2>/dev/null; "
        f"sudo docker compose up -d --build",
        timeout=900,
    )
    if code != 0:
        raise SystemExit(f"compose failed: {code}")

    time.sleep(3)
    run(client, "sudo docker compose -f /home/mobile/track-deploy/docker-compose.yml ps")
    run(
        client,
        f"curl -sS -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{PORT}/ && echo "
        f"&& curl -sS -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{PORT}/api/v1/overview?from=2020-01-01T00:00:00Z\\&to=2030-01-01T00:00:00Z && echo",
    )
    print(f"\nREADY: http://{HOST}:{PORT}/")
    client.close()


if __name__ == "__main__":
    main()
