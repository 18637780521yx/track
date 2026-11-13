"""Build and deploy the Track console and Python API over OpenSSH."""

import argparse
import shlex
import subprocess
import tarfile
import tempfile
from pathlib import Path
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
CONSOLE = ROOT / "track-console"
PORTS = {"test": 18765, "prod": 28643}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("environment", choices=PORTS)
    parser.add_argument("--host", default="mobile@10.10.10.132")
    args = parser.parse_args()

    subprocess.run(
        ["node", "node_modules/typescript/bin/tsc", "-b"], cwd=CONSOLE, check=True
    )
    subprocess.run(
        ["node", "node_modules/vite/bin/vite.js", "build"], cwd=CONSOLE, check=True
    )

    env = args.environment
    port = PORTS[env]
    remote_bundle = f"/tmp/track-{uuid4().hex}.tar.gz"
    with tempfile.TemporaryDirectory() as directory:
        bundle = Path(directory) / "track.tar.gz"
        with tarfile.open(bundle, "w:gz") as archive:
            for name in ("Dockerfile", "requirements.txt", "app", "migrations"):
                archive.add(
                    ROOT / "track-server-py" / name,
                    arcname=f"track-server-py/{name}",
                    filter=lambda item: None if "__pycache__" in Path(item.name).parts else item,
                )
            archive.add(CONSOLE / "dist", arcname="track-console-dist")

        subprocess.run(["scp", str(bundle), f"{args.host}:{remote_bundle}"], check=True)

    # Reuse the installed Compose and nginx configuration, including its database volume.
    compose = f"sudo docker compose --env-file .env.{env} -p track-{env}"
    commands = f"""
set -eu
trap 'rm -f {remote_bundle}' EXIT
cd /home/mobile/track-deploy
test -f .env.{env}
test -f docker-compose.yml
tar -xzf {remote_bundle}
{compose} up -d --build server web
curl -fsS --retry 10 --retry-delay 2 --retry-all-errors http://127.0.0.1:{port}/ -o /dev/null
curl -fsS --retry 10 --retry-delay 2 --retry-all-errors http://127.0.0.1:{port}/api/v1/apps
"""
    subprocess.run(["ssh", "-t", args.host, "bash -c " + shlex.quote(commands)], check=True)
    print(f"Track {env} deployed on port {port}.")


if __name__ == "__main__":
    main()
