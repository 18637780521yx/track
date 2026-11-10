import os
import paramiko

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("10.10.10.132", username="mobile", password=os.environ["TRACK_SSH_PASSWORD"], timeout=15)


def run(cmd: str) -> None:
    print(">>>", cmd)
    _, stdout, stderr = c.exec_command(cmd, timeout=60)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    if out:
        print(out)
    if err:
        print("ERR:", err)


run("uname -a; whoami; pwd; df -h / | tail -1")
run(
    "which docker docker-compose nginx node npm python3 python 2>/dev/null; "
    "command -v docker; command -v nginx; command -v node; command -v python3"
)
run("ls -la ~ | head -40")
run("ss -lntp 2>/dev/null | head -40 || netstat -lntp 2>/dev/null | head -40")
run("cat /etc/os-release 2>/dev/null | head -8")
c.close()
