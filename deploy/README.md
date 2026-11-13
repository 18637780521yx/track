# Track 部署（测试 / 线上）

在 Track 仓库根目录运行：

```powershell
python deploy/publish.py test
python deploy/publish.py prod
```

首次使用需在 `track-console` 安装依赖（`npm ci`）。脚本默认通过 OpenSSH 登录
`mobile@10.10.10.132`，也可用 `--host 用户@主机` 指定。SSH 和 sudo
需要密码时会由终端提示输入。首次连接请核对 SSH 主机指纹。

脚本构建管理后台，上传前端产物和 Python API，使用服务器现有的 Compose 配置和对应环境的数据库卷，并检查首页及应用列表接口。

同一台机两套互不影响的栈：独立数据库卷、独立端口、独立 compose 项目名。

| 环境 | 端口 | 控制台 | 上报 |
|------|------|--------|------|
| 测试 test | **18765** | http://HOST:18765/ | http://HOST:18765/track |
| 线上 prod | **28643** | http://HOST:28643/ | http://HOST:28643/track |

```bash
cd /home/mobile/track-deploy

# 测试
sudo docker compose --env-file .env.test -p track-test up -d --build

# 线上
sudo docker compose --env-file .env.prod -p track-prod up -d --build
```

本地调试仍可用 `127.0.0.1:8080`；App 按业务环境自动选测试/线上地址。
