# Track Server (Python)

FastAPI 埋点服务：接收 SDK 上报 + 分析查询 API。  
与 Go `track-server` / `track-console` / Flutter `fast_track` / Android `fast_track_android` **协议兼容**。

```
SDK (Flutter / Android)
        │  POST /track
        ▼
 track-server-py  ──►  Postgres
        ▲
        │  GET/POST /api/v1/*
 track-console
```

---

## 1. 快速启动

### Docker（推荐）

```bash
cd track/track-server-py
docker compose up -d
curl http://127.0.0.1:8080/health
# {"ok":true}
```

默认：

| 服务 | 地址 |
|------|------|
| API | `http://localhost:8080` |
| Postgres | `localhost:5432`，库/用户/密码均为 `track` |

### 本地开发

```bash
cd track/track-server-py
docker compose up -d postgres

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

export ADDR=":8080"
export DATABASE_URL="postgres://track:track@localhost:5432/track?sslmode=disable"
python -m app.main
```

启动时自动执行 `migrations/*.sql`（`IF NOT EXISTS`，可重复跑）。

### 对接分析后台

```bash
cd track/track-console
npm install
# 可选：指向本机 Python 服务
export VITE_API_PROXY=http://127.0.0.1:8080
npm run dev
```

浏览器打开 http://localhost:3000 。

---

## 2. 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `ADDR` | `:8080` | 监听地址；`:8080` 表示 `0.0.0.0:8080` |
| `DATABASE_URL` | `postgres://track:track@localhost:5432/track?sslmode=disable` | Postgres 连接串 |

无鉴权；CORS 允许 `*` + `GET, POST, OPTIONS`。

---

## 3. 目录结构

```
track-server-py/
├── app/
│   ├── main.py              # FastAPI 入口
│   ├── config.py
│   ├── models.py            # 请求/响应 DTO
│   ├── db/pool.py           # asyncpg + 迁移
│   ├── routers/
│   │   ├── ingest.py        # POST /track
│   │   ├── analytics.py     # 业务分析 API
│   │   └── stability.py     # 崩溃/ANR API
│   └── services/
│       ├── sync.py          # ingest + 衍生表
│       ├── analytics.py
│       ├── stability.py
│       └── parse.py
├── migrations/              # 001~004 SQL
├── Dockerfile
├── docker-compose.yml
└── requirements.txt
```

---

## 4. API 一览

### 基础

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/health` | 健康检查 `{"ok":true}` |
| POST | `/track` | SDK 批量上报（主入口） |
| POST | `/api/v1/track` | 同上别名 |

### 业务分析（`/api/v1`）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/overview` | 概览（DAU / 收入 / Top 事件 / 趋势） |
| GET | `/events/names` | 事件名列表 |
| GET | `/events/trend` | 事件趋势 |
| GET | `/events` | 事件明细 |
| GET | `/events/property-values` | 属性枚举值 |
| POST | `/funnel` | 漏斗 |
| GET | `/retention` | 留存 |
| GET | `/users` | 用户列表 |
| GET | `/users/{id}` | 用户详情 |
| GET | `/users/{id}/events` | 用户事件流（不含 app_log） |
| GET | `/users/{id}/logs` | 用户终端日志（`app_logs` 表） |

### 稳定性（`/api/v1/stability`）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/overview` | crash / error / anr 计数与趋势 |
| GET | `/issues` | Issue 列表（按 fingerprint 聚合） |
| GET | `/issues/{fingerprint}` | Issue 详情 + 事件样本 |

时间参数统一：`from` / `to` 为 **RFC3339**；缺省为最近 7 天 → now（UTC）。  
事件过滤多为半开区间：`event_time >= from AND event_time < to`。

---

## 5. 上报 `POST /track`

### 请求

- `Content-Type: application/json`
- 可选 `Content-Encoding: gzip`
- Body：

```json
{
  "events": [
    {
      "event_id": "uuid",
      "name": "page_view",
      "properties": { "page": "home" },
      "common_properties": { "device_os": "android", "sdk_version": "0.1.0" },
      "distinct_id": "user_1",
      "anonymous_id": "anon_1",
      "session_id": "sess_1",
      "timestamp": "2026-09-29T12:00:00.000Z"
    }
  ]
}
```

`timestamp` 支持：RFC3339、Unix 秒（含小数）、`YYYY-MM-DDTHH:MM:SS[.mmm]` 等。

### 响应

```json
{ "ok": true, "total": 3, "stored": 2, "dropped": 1 }
```

| 规则 | 行为 |
|------|------|
| 空 `event_id` / `name` | drop |
| `event_id` 冲突 | `ON CONFLICT DO NOTHING` → dropped |
| 空 `anonymous_id` / `session_id` | 填 `"unknown"` |
| 空 / 零时间戳 | 用服务器 UTC now |

### curl 示例

```bash
curl -sS -X POST http://127.0.0.1:8080/track \
  -H 'Content-Type: application/json' \
  -d '{
    "events": [{
      "event_id": "demo-1",
      "name": "page_view",
      "properties": {"page":"home"},
      "common_properties": {"device_os":"android"},
      "distinct_id": "demo_alice",
      "anonymous_id": "anon_a",
      "session_id": "sess_a",
      "timestamp": "2026-09-29T12:00:00.000Z"
    }]
  }'
```

---

## 6. 约定业务事件

ingest 成功后会同步衍生表（`users` / `subscriptions` / `daily_*`）：

| 事件名 | 作用 | 关键 properties |
|--------|------|------------------|
| `app_first_open` | 首开 / 安装 | `channel` |
| `user_signup` | 注册时间 | `method` |
| `payment_success` | 收入、付费用户 | `amount`, `currency` |
| `subscription_start` | 新建订阅 | `plan`, `amount`, `expires_at` |
| `subscription_renew` | 续订 | `expires_at` |
| `subscription_cancel` | 取消订阅 | — |

用户 ID：优先 `distinct_id`，否则 `anonymous_id`。

---

## 7. 分析 API 详解

公共 Query：`from`、`to`（RFC3339）。  
`filters`（可选）：URL 编码的 JSON 数组：

```json
[
  { "source": "common", "field": "device_os", "op": "eq", "value": "android" }
]
```

| 字段 | 说明 |
|------|------|
| `source` | `common` / `properties` |
| `op` | `eq` / `neq` / `contains` |

### `GET /api/v1/overview`

```bash
curl "http://127.0.0.1:8080/api/v1/overview?from=2026-09-22T00:00:00Z&to=2026-09-30T00:00:00Z"
```

返回：`dau`、`new_users`、`installs`、`revenue`、`paying_users`、`active_subscriptions`、`total_events`、`top_events`、`trend`。

### `GET /api/v1/events/names?q=`

模糊搜事件名，返回 `{ "items": [{ "name", "count" }] }`。

### `GET /api/v1/events/trend`

| Query | 说明 |
|-------|------|
| `event` | 可选，单事件 |
| `unit` | `day` / `hour` / `week` |
| `filters` | 可选 |

返回 `{ "items": [{ "bucket", "count", "users" }] }`。

### `GET /api/v1/events`

| Query | 默认 |
|-------|------|
| `event` | 全部 |
| `limit` | 50（最大 200） |
| `offset` | 0 |
| `filters` | — |

返回 `{ "items": [EventRecord], "total" }`。

### `GET /api/v1/events/property-values`

| Query | 说明 |
|-------|------|
| `field` | 必填 |
| `source` | 默认 `common` |
| `event` | 可选 |
| `limit` | 默认 50 |

### `POST /api/v1/funnel`

```bash
curl -X POST http://127.0.0.1:8080/api/v1/funnel \
  -H 'Content-Type: application/json' \
  -d '{
    "steps": ["page_view", "button_click", "payment_success"],
    "from": "2026-09-22T00:00:00Z",
    "to": "2026-09-30T00:00:00Z",
    "window_hours": 24
  }'
```

返回每步 `users` 与相对第一步的 `conversion`（百分比）。  
注意：步骤之间要求 **严格时间递增**（`event_time >` 上一步），同毫秒多事件可能导致后步为 0。

### `GET /api/v1/retention`

| Query | 默认 |
|-------|------|
| `cohort_event` | `app_start` |
| `return_event` | 同 cohort |
| `days` | 7 |

### 用户

```bash
curl "http://127.0.0.1:8080/api/v1/users?q=alice&limit=50"
curl "http://127.0.0.1:8080/api/v1/users/demo_alice"
curl "http://127.0.0.1:8080/api/v1/users/demo_alice/events?from=...&to=..."
```

不存在返回 `404 {"error":"user not found"}`。

---

## 8. 稳定性 API

SDK 上报事件名：

| name | kind |
|------|------|
| `app_crash` | `crash` |
| `app_error` | `error` |
| `app_anr` | `anr` |

这三类**不进**业务表 `events`，写入：

- `stability_events` — 原始稳定性事件
- `stability_issues` — 按 `fingerprint` 聚合
- `stability_issue_users` — 影响用户去重

### App 日志隔离

`app_log` **不进** `events`，写入 `app_logs`，且**不计入** `daily_stats.total_events` / overview 热门事件。

客户端仍走 `POST /track`（可与埋点同批）；服务端按事件名旁路。迁移 `005_app_logs.sql` 会把历史 `events` 里的 `app_log` 迁出并删除。

**保留策略：** 仅保留最近 **2 小时**（后台每分钟清理；查询也会钳制时间窗）。超过 TTL 的上报直接丢弃。

### `GET /api/v1/users/{id}/logs?from&to&limit&offset&order&level`

返回 `{ items, total, ttl_hours }`（形状与事件流一致）；`items[].name` 为 `app_log`，`properties` 含 `level` / `tag` / `message`。

### `DELETE /api/v1/users/{id}/logs`

清空该用户全部终端日志，返回 `{ ok, deleted }`。

### `GET /api/v1/stability/overview?from&to`

返回 `crash` / `error` / `anr` 计数、`issue_count`、`affected_users`、按日 `trend`。

### `GET /api/v1/stability/issues`

| Query | 说明 |
|-------|------|
| `kind` | 可选：`crash` / `error` / `anr` |
| `limit` / `offset` | 分页 |
| `from` / `to` | 时间窗 |

返回 `{ "items": [StabilityIssueSummary], "total" }`。

### `GET /api/v1/stability/issues/{fingerprint}`

返回 `{ "issue", "events", "total" }`；不存在 `404`。

### 稳定性上报示例

```bash
curl -X POST http://127.0.0.1:8080/track \
  -H 'Content-Type: application/json' \
  -d '{
    "events": [{
      "event_id": "crash-1",
      "name": "app_crash",
      "properties": {
        "exception_type": "java.lang.RuntimeException",
        "message": "boom",
        "stack": "at com.example.Main...",
        "thread": "main",
        "is_fatal": true,
        "fingerprint": "abc123"
      },
      "common_properties": {
        "app_version": "1.0.0",
        "device_model": "Pixel 7"
      },
      "anonymous_id": "anon_x",
      "session_id": "sess_x",
      "timestamp": "2026-09-29T12:00:00.000Z"
    }]
  }'
```

---

## 9. 数据表（迁移）

| 文件 | 内容 |
|------|------|
| `001_init.sql` | `events` |
| `002_derived_tables.sql` | `users` / `subscriptions` / `daily_stats` / DAU&付费去重 |
| `003_install_dedup.sql` | `daily_install_users` |
| `004_stability.sql` | `stability_issues` / `stability_events` / `stability_issue_users` |
| `005_app_logs.sql` | `app_logs`（并从 `events` 迁出历史 `app_log`） |

---

## 10. 与 SDK / Console 联调

| 客户端 | 上报地址 |
|--------|----------|
| Android 模拟器 | `http://10.0.2.2:8080/track` |
| 本机 Flutter / curl | `http://127.0.0.1:8080/track` |
| 真机 | `http://<电脑局域网IP>:8080/track` |

```bash
# 健康检查
curl http://127.0.0.1:8080/health

# 概览
curl "http://127.0.0.1:8080/api/v1/overview"

# 稳定性概览
curl "http://127.0.0.1:8080/api/v1/stability/overview"
```

OpenAPI 文档（FastAPI 自带）：http://127.0.0.1:8080/docs

---

## 12. 线上部署（wanren，无 Docker 跑服务）

已部署到 `101.126.68.169`：

| 入口 | 说明 |
|------|------|
| http://101.126.68.169:5000/ | Console 静态站 |
| http://101.126.68.169:5000/track | 上报 |
| http://101.126.68.169:5000/api/v1/* | 分析 API |
| http://101.126.68.169:5000/health | 健康检查 |

架构：nginx `:5000` → 静态 console + 反代 uvicorn `127.0.0.1:18100`；库用本机已有 Postgres `:5434` 的 `track` 库（非新建 Docker）。

```bash
# 更新 Python
rsync -az --exclude .venv track-server-py/ wanren:/opt/track/server/
ssh wanren 'systemctl restart track-server-py'

# 更新 Console
rsync -az --exclude node_modules --exclude dist track-console/ wanren:/opt/track/console-src/
ssh wanren 'export NVM_DIR=/root/.nvm; . $NVM_DIR/nvm.sh; nvm use 22.15.0; cd /opt/track/console-src && npm i && npm run build && rm -rf /opt/track/console && mkdir -p /opt/track/console && cp -a dist/. /opt/track/console/'
```

systemd：`track-server-py.service`；nginx：`/etc/nginx/conf.d/track-5000.conf`。
