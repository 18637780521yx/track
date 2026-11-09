# Track 部署（测试 / 线上）

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
