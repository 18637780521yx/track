# Track 埋点平台

Flutter / Android SDK + Python 服务端 + 分析后台。

```
track/
├── scripts/maintenance/   # 部署、诊断与历史 Git 辅助脚本
├── fast_track/            # Flutter 上报 SDK（纯管道）
├── fast_track_mcp/        # 检测 + Bridge +（可选）Cursor MCP
├── fast_track_android/    # Android Kotlin 上报 SDK
├── track-server-py/       # Python 服务端（推荐）
├── track-server/          # Go 服务端（参考）
└── track-console/         # 分析后台（含 /reports 会话报告）
```

## 测试 / 线上部署

辅助脚本的用途与运行方式见 [scripts/maintenance/README.md](scripts/maintenance/README.md)。

同一台机两套独立栈（库与端口隔离），见 [deploy/README.md](deploy/README.md)：

| 环境 | 控制台 | App 上报 |
|------|--------|----------|
| 测试 | http://10.10.10.132:18765/ | `…:18765/track` |
| 线上 | http://10.10.10.132:28643/ | `…:28643/track` |

App 随业务 `Env`（云测试 / 正式）自动选地址；可用 `--dart-define=FAST_TRACK_URL=` 覆盖。

## 快速启动（Python）

```bash
cd track-server-py
# Postgres 已就绪时：
python -m venv .venv && .venv/Scripts/activate   # Windows
pip install -r requirements.txt
set DATABASE_URL=postgres://track:track@localhost:5432/track?sslmode=disable
python -m app.main
```

服务默认 `http://localhost:8080`（`POST /track`，`GET /health`）。

埋点与会话报告相关数据默认只保留 **7 天**（`TRACK_RETENTION_DAYS`，后台每小时清理；终端 `app_log` 仍为 2 小时）。

分析后台：

```bash
cd track-console
npm install && npm run dev
# http://localhost:3000  → 会话报告 /reports
```

## Flutter

**只上报：** 见 [fast_track/README.md](fast_track/README.md)

**上报 + 崩溃/性能检测（推荐）：** 见 [fast_track_mcp/docs/INTEGRATION.md](fast_track_mcp/docs/INTEGRATION.md)

要点：

1. `FastTrackMcpCrashHandler.run` 包住 `main`
2. 先 `FastTracker.init`，再 `FastTrackMcp.ensureInitialized`（Debug/Profile）
3. 真机：`adb reverse tcp:8080 tcp:8080`（及 Bridge `19288`）

```bash
cd fast_track_mcp/example_app
flutter run --profile --no-dds
```

## Android SDK

```bash
cd fast_track_android
# 模拟器上报：http://10.0.2.2:8080/track
```

```kotlin
FastTracker.init(this, "http://host:8080/track")
FastTracker.track("page_view", mapOf("page" to "home"))
```

## API

| 接口 | 说明 |
|------|------|
| `POST /track` | SDK 批量上报 |
| `GET /api/v1/overview` | 数据概览 |
| `GET /api/v1/events*` | 事件查询 |
| `POST /api/v1/funnel` | 漏斗 |
| `GET /api/v1/retention` | 留存 |
| `GET /api/v1/users*` | 用户 |
