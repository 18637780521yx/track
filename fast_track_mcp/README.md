# Fast Track MCP

Flutter **性能检测 + Bridge +（可选）Cursor MCP 自动化**。事件上报走 [`flutter_fast_track`](../fast_track/README.md)。

**当前版本：0.10.x（App SDK 自有 detect，无 Sleuth）**

## 一句话架构

```
业务 App
  ├─ FastTracker.init          → POST /track → track-server-py → track-console /reports
  └─ FastTrackMcp.ensureInitialized
        ├─ detect：crash / ANR / jank / memory
        ├─ 手势 / 转场 / HTTP 抓包
        └─ Bridge :19288  ←── Cursor mcp_server / curl（可选）
```

## 目录

```
fast_track_mcp/
├── protocol/       # { code, data, msg } 契约
├── app_sdk/        # 嵌进被测 App（必接）
├── mcp_server/     # Cursor MCP（可选）
├── example_app/    # Demo
├── docs/           # 接入 · 使用
└── perf_agent_config.json
```

## 文档

| 文档 | 内容 |
|------|------|
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | **接到业务 App（必读）** |
| [docs/USAGE.md](docs/USAGE.md) | Cursor MCP / 命令行 / 控制台报告 |
| [CHANGELOG.md](CHANGELOG.md) | 版本记录 |
| [../fast_track/README.md](../fast_track/README.md) | 纯上报 SDK |

## 60 秒：只看埋点报告（无 Cursor）

```bash
# 1) track-server-py :8080
# 2) track-console :3000 → http://localhost:3000/reports
# 3) App 按 INTEGRATION 接入后 Debug 运行
adb reverse tcp:8080 tcp:8080
adb reverse tcp:19288 tcp:19288   # 可选，给 Bridge
```

## 60 秒：example + MCP

```bash
cd app_sdk && flutter pub get
cd ../mcp_server && dart pub get
cd ../example_app && flutter pub get

cd example_app && flutter run --profile --no-dds
# 另开终端
curl http://127.0.0.1:19288/health
```

Cursor 配置见 [docs/INTEGRATION.md](docs/INTEGRATION.md) § MCP。

## MCP 工具（常用）

| Tool | 说明 |
|------|------|
| `start_perf_test` / `stop_perf_test` | 开会话 / 出报告 |
| `tap` / `input_text` / `scroll` | UI 操作（可自动开会话） |
| `get_ui_snapshot` | 可交互控件 |
| `skill_call` / `skill_list_methods` | flutter_skill 全量 |
| `screenshot` | 按需截图 |

`get_sleuth_*` **已下线**（0.10）。告警看会话报告 / Bridge snapshot。

## Debug / Profile / Release

| 能力 | Debug/Profile | Release |
|------|---------------|---------|
| `FastTrackMcpCrashHandler` 崩溃采集 | ✅ | ✅（需包住 main） |
| FastTracker 上报 | ✅ | ✅（真实 URL，非 dryRun） |
| ANR / jank / memory | ✅ | ✅ |
| 手势 / Tab 转场账本 | ✅ | ✅（`releaseUiHooks`，无 Bridge） |
| HTTP 抓包 | ✅ 可带 body | ✅ 成功无 body，**仅失败带 body** |
| Bridge / MCP 自动化 | ✅ | ❌ |
| LeakOnline / WeakRef 全量 | Debug 默认可开 | 可选采样 |

## 注意

- **必须先 `FastTracker.init`，再 `FastTrackMcp.ensureInitialized`**
- 真机：`adb reverse tcp:8080`（上报）+ `tcp:19288`（Bridge）
- 可信帧指标建议 `--profile`
- `HttpOverrides` 由本 SDK 独占；排除 `/track` 上报 URL
