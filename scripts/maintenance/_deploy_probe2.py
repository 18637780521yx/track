import os
import paramiko

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("10.10.10.132", username="mobile", password=os.environ["TRACK_SSH_PASSWORD"], timeout=15)


def run(cmd: str) -> None:
    print(">>>", cmd)
    _, stdout, stderr = c.exec_command(cmd, timeout=90)
    print(stdout.read().decode("utf-8", errors="replace"))
    err = stderr.read().decode("utf-8", errors="replace")
    if err:
        print("ERR:", err)


run('docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}" | head -40')
run("groups; id")
run("sudo -n true; echo sudo_exit=$?")
run("ls /etc/nginx/sites-enabled 2>/dev/null; ls /var/www 2>/dev/null | head")
run("command -v node; command -v npm; node -v 2>&1; npm -v 2>&1")
run("docker compose version 2>&1; docker-compose version 2>&1 | head -3")
c.close()
