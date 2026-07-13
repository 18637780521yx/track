# Track 埋点平台

Flutter SDK + Go 服务端 + 自研分析平台（仿神策 MVP）。

```
track/
├── fast_track/       # Flutter 埋点 SDK（已有）
├── track-server/     # Go 服务端：接收上报 + 分析查询 API
└── track-console/    # React 分析后台：概览 / 事件 / 漏斗 / 留存
```

## 数据模型

```
events              ← 宽表，所有埋点原始记录（只增不改）
  ↓ ingest 时同步
users               ← 用户画像（首次/最后访问、是否付费、累计收入）
subscriptions       ← 订阅状态（active / cancelled）
daily_stats         ← 日维度预聚合（DAU、新增、安装、收入）
daily_active_users  ← 日活去重辅助
daily_paying_users  ← 每日付费用户去重
```

### 约定埋点事件

| 事件名 | 用途 | 关键属性 |
|--------|------|----------|
| `app_first_open` | 安装/首开 | `channel` |
| `user_signup` | 注册 | `method` |
| `payment_success` | 付费 | `amount`, `currency` |
| `subscription_start` | 开始订阅 | `plan`, `amount`, `expires_at` |
| `subscription_renew` | 续订 | `expires_at` |
| `subscription_cancel` | 取消订阅 | — |

## 快速启动

### 1. 启动数据库和服务端

```bash
cd track-server
docker compose up -d postgres   # 仅数据库
# 或
docker compose up -d            # 数据库 + Go 服务

# 本地跑 Go（开发推荐）
export DATABASE_URL="postgres://track:track@localhost:5432/track?sslmode=disable"
go run ./cmd/server
```

服务默认监听 `http://localhost:8080`

### 2. 启动分析后台

```bash
cd track-console
npm install
npm run dev
```

打开 http://localhost:3000

### 3. 用 fast_track 上报演示数据

```bash
# 终端 1：Go 服务
cd track-server && go run ./cmd/server

# 终端 2：分析后台
cd track-console && npm run dev

# 终端 3：iOS 模拟器批量上报（13 条演示事件）
cd fast_track/example
flutter run -t ../tool/send_demo_events.dart -d <模拟器ID>
```

演示脚本会模拟 3 个用户：
- **demo_alice**：首开 → 浏览 → 点击 → 付费 → 订阅
- **demo_bob**：首开 → 浏览 → 点击（未付费）
- **匿名用户**：首开 → 浏览

打开 http://localhost:3000 查看概览、漏斗、事件分析。

### 4. 联调 fast_track example 应用

```bash
# 终端 1：Go 服务（若未用 docker compose 跑 server）
cd track-server && go run ./cmd/server

# 终端 2：Flutter 示例
cd fast_track/example
flutter run --dart-define=TRACK_HOST=127.0.0.1
```

将 example 中的上报地址指向 `http://<host>:8080/track`（与 Go 服务兼容）。

## API

| 接口 | 说明 |
|------|------|
| `POST /track` | SDK 批量上报（兼容 fast_track） |
| `GET /api/v1/overview` | 数据概览 |
| `GET /api/v1/events/names` | 事件列表 |
| `GET /api/v1/events/trend` | 事件趋势 |
| `GET /api/v1/events` | 事件明细 |
| `POST /api/v1/funnel` | 漏斗分析 |
| `GET /api/v1/retention` | 留存分析 |

上报格式（与 fast_track 一致）：

```json
{
  "events": [
    {
      "event_id": "uuid",
      "name": "page_view",
      "properties": {},
      "common_properties": {},
      "distinct_id": "user_1",
      "anonymous_id": "anon_1",
      "session_id": "sess_1",
      "timestamp": "2026-07-13T03:00:00.000Z"
    }
  ]
}
```

## 分析平台功能（MVP）

- **数据概览**：UV、事件总量、趋势图、Top 事件
- **事件分析**：单事件趋势 + 明细表
- **漏斗分析**：多步骤转化（时序 + 时间窗口）
- **留存分析**：按 cohort 日期展示 N 日留存热力表

## 后续规划

- [ ] 多项目 / App Key 隔离
- [ ] 用户权限与登录
- [ ] 事件元数据管理（属性字典）
- [ ] ClickHouse 迁移（大数据量）
- [ ] 用户行为路径、分布分析
