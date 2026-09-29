# Track 埋点平台

Flutter / Android SDK + Python 服务端 + 自研分析平台（仿神策 MVP）。

```
track/
├── fast_track/            # Flutter 埋点 SDK
├── fast_track_android/    # Android Kotlin 埋点 SDK
├── track-server-py/       # Python 服务端（推荐）：接收上报 + 分析查询 API
├── track-server/          # Go 服务端（参考实现，API 兼容）
└── track-console/         # React 分析后台
```

## 快速启动（Python）

```bash
cd track-server-py
docker compose up -d            # Postgres + FastAPI
# 或仅 DB + 本地 Python：
docker compose up -d postgres
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export DATABASE_URL="postgres://track:track@localhost:5432/track?sslmode=disable"
python -m app.main
```

服务默认 `http://localhost:8080`。

分析后台：

```bash
cd track-console
npm install && npm run dev
# 可选：VITE_API_PROXY=http://127.0.0.1:8080
```

## Android SDK

```bash
cd fast_track_android
# Android Studio 打开工程，运行 demo
# 模拟器上报地址：http://10.0.2.2:8080/track
```

```kotlin
FastTracker.init(this, "http://host:8080/track")
FastTracker.track("page_view", mapOf("page" to "home"))
```

## Flutter SDK

```bash
cd fast_track/example
flutter run --dart-define=TRACK_HOST=127.0.0.1
```

## 约定埋点

| 事件名 | 用途 | 关键属性 |
|--------|------|----------|
| `app_first_open` | 安装/首开 | `channel` |
| `user_signup` | 注册 | `method` |
| `payment_success` | 付费 | `amount`, `currency` |
| `subscription_start` | 开始订阅 | `plan`, `amount`, `expires_at` |
| `subscription_renew` | 续订 | `expires_at` |
| `subscription_cancel` | 取消订阅 | — |

## API

| 接口 | 说明 |
|------|------|
| `POST /track` | SDK 批量上报 |
| `GET /api/v1/overview` | 数据概览 |
| `GET /api/v1/events/*` | 事件名 / 趋势 / 明细 |
| `POST /api/v1/funnel` | 漏斗 |
| `GET /api/v1/retention` | 留存 |
| `GET /api/v1/users*` | 用户 |
