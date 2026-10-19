# Changelog

## 0.6.7 — example_app 迁入 Sleuth 官方场景页

- 将 sleuth 0.37 example 的 demos / Capture Helpers / custom_detectors 迁入 `example_app/lib/sleuth_demos`
- 「发现」Tab 改为「场景」目录，分组入口打开各 Demo；路由记为 `/demo/<slug>`
- 开启 `enableDeepDebugInstrumentation` + cookbook `customDetectors`（与官方 example 对齐）

## 0.6.6 — 冷启动方案 A 分阶段

- 从 Sleuth startup 推导阶段：Pre-Dart / Framework / 业务启动 / 首帧(vsync·build·raster) / TTFF / TTI
- HTML 冷启动章展示分阶段表 + 占比条；主指标以 TTFF 为准（方案 A）

## 0.6.5 — 路由章内线性事件时间线

- 同路由操作写入 `events[]`：screenshot → action → network → navigate
- 切路由时：源章保留操作/请求/跳转事件；目标章单独落页截图
- HTML 以时间线展示章内事件（含内嵌截图）

## 0.6.4 — 冷启动步骤

- 报告首步固定为 `cold_start`（不与后续同路由操作合并）：Sleuth TTFF/TTI + 首屏截图
- example_app 调用 `Sleuth.init()` / `markInteractive`；Bridge `GET /sleuth/startup`
- 可选 `coldStart.relaunch`：kill + 打开 macOS `.app` 并统计进程就绪耗时
- HTML 冷启动卡片展示 TTFF / TTI / processLaunchMs

## 0.6.3 — 按路由记录步骤

- 报告步骤改为**路由落页**：同路由上的多次操作合并进一个 step；切路由则新开 step（避免登录后立刻进「我的」时漏掉首页截图）
- Bridge `GET /app/route`；example_app 逻辑路由含 Tab（`/home#home|discover|mine`）
- `start_perf_test` 先拍一张起始路由基线；切路由后额外 settle + 截图重试
- 报告 `schemaVersion=7`；HTML 标题展示路由与合并后的操作链

## 0.6.2 — 操作即采样

- UI 工具（`tap` / `input_text` / `scroll` / `skill_call` 手势）无会话时**自动开会话**
- 每步自动 Sleuth/RSS diff，并覆盖写入 `reports/live_<sessionId>.{json,html}`
- `stop_perf_test` 仍写出最终报告；`start_perf_test` 改为可选

## 0.6.1 — MCP skill 工具收拢

- 去掉 40+ `skill_*` 单工具；改为 `skill_call`（method+args）+ `skill_screenshot` + `skill_list_methods`
- 手势类 method 仍走 ActionRunner（Sleuth/RSS）；`FlutterSkillClient` 接口不变

## 0.6.0 — ApiResponse(code/data/msg) + 模型化

- 新增纯 Dart 包 `protocol/`（`flutter_perf_agent_protocol`）：统一 `{ code, data, msg }`
- Bridge HTTP / MCP tool / SleuthFacade / UiActions / BridgeClient / ActionRunner 全部改用模型
- 去掉散落的 `ok` / `error` Map；业务码见 `ApiCodes`（`0`=成功）
- 报告 `schemaVersion=6`；app_sdk / mcp_server → `0.6.0`

## 0.5.1 — flutter_skill 完整能力

- `FlutterSkillVmClient` 覆盖 flutter_skill 全部 VM 扩展（手势 / 检查 / 等待 / 截图 / 导航 / 日志 / HTTP / 指示器等）
- MCP：`skill_*` 工具全量暴露；手势类在会话中走 ActionRunner（Sleuth/RSS diff）
- 保留原有 `tap` / `scroll` / `input_text` / `get_ui_snapshot` 快捷入口
- 未暴露 app 侧写入用扩展 `logHttpRequest`（由被测 App 调用）

## 0.5.0 — Sleuth 完整能力

- Bridge：`/sleuth/snapshot|summary|diagnose|issues|route_health`
- MCP：`get_sleuth_*` 五件套；每步附带 live issues；stop 写入完整快照
- example_app：全量 detector + overlay + 内存预算；建议 `--profile --no-dds`
- 报告 schemaVersion=5（含 sleuthDiagnose / summary / final snapshot）

## 0.4.1 — Sleuth-only 指标

- **性能指标只走 Sleuth + RSS**（PerfBridge snapshot）
- 去掉动作窗 DevTools 采样与相关 MCP 工具（Timeline/CPU/Heap/Inspector/Network/Logs/debug）
- VM WebSocket **仅**用于 flutter_skill UI（点击/输入/滑动/截图）
- 保留 `export/import_session_snapshot`

## 0.4.0 — DevTools VM（程序化，已回退指标路径）

- 曾接入 Timeline / CPU / Heap / HttpProfile / Inspector 等（0.4.1 起指标侧不再使用）
- **本期不做**：App Size、Deep links

## 0.3.0 — Phase3 / V1

- 会话内复用 flutter_skill VM 连接
- 开会话前自动 stop 残留 session
- 登录类 tap 增加导航等待；通用 post-action settle
- 步骤截图写入 reports/screenshots，HTML 嵌入
- 文档：接入、使用、Demo；`scripts/demo.sh`
- 报告 schemaVersion=3

## 0.2.0 — Phase2

- MCP：`input_text` / `scroll`
- JSON + HTML 报告
- 动作重试、debugLog

## 0.1.0 — Phase1

- MCP：`start_perf_test` / `tap` / `stop_perf_test`
- App Bridge + Sleuth 打点
- example_app 登录 Demo
