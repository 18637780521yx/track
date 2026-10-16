# Changelog

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
