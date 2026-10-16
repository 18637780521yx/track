# Flutter-Perf-Agent

自然语言驱动 Flutter App：**UI 自动化 + 性能打点 + JSON/HTML 报告**。

**当前版本：V1（0.6.0 code/data/msg + Sleuth + flutter_skill 全量）**

## 一句话架构

```
Cursor MCP
  ├─ flutter_skill 全量（tap/scroll/input + skill_* …）
  └─ PerfBridge + Sleuth 全量
       信封统一：{ code, data, msg }  （protocol 包）
```

> GC / 堆 / shader 等 VM 型 detector：请用 `flutter run --profile --no-dds`  
> （DDS 占着 VM 时 Sleuth 连不上，这些 detector 会哑火。）

## 目录

```
flutter-perf-agent/
├── protocol/          # 纯 Dart：ApiResponse + DTO（Bridge/MCP 契约）
├── app_sdk/           # 嵌进被测 App
├── mcp_server/        # Cursor MCP（dart_mcp）
├── example_app/       # 登录 → 列表 Demo
├── scripts/demo.sh    # 一键冒烟
├── reports/           # JSON / HTML / screenshots
├── docs/              # 接入 · 使用 · Demo
└── perf_agent_config.json
```

## 60 秒上手

```bash
# 依赖
cd app_sdk && flutter pub get
cd ../mcp_server && dart pub get
cd ../example_app && flutter pub get

# 终端1：跑 App
cd example_app && flutter run -d macos --profile   # 或 --debug

# 终端2：冒烟
cd .. && chmod +x scripts/demo.sh && ./scripts/demo.sh
```

Cursor 里配置 MCP 后可以说：

> 启动性能测试「登录到列表滑动」：password_field 输入 123456，点登录，向下滑两次，停止并给报告路径。

## MCP 工具

| Tool | 说明 |
|------|------|
| `start_perf_test` | 开会话（清理旧会话） |
| `input_text` / `tap` / `scroll` | 常用 UI + Sleuth/RSS diff |
| `skill_*` | **flutter_skill 全量**（见下） |
| `stop_perf_test` | JSON + HTML（含截图） |
| `get_ui_snapshot` | 可交互控件（inspect） |
| `export_session_snapshot` / `import_session_snapshot` | 会话快照 I/O |
| `get_sleuth_snapshot` | 完整 Sleuth 会话快照 |
| `get_sleuth_issues` | detector issues（含 fixHint） |
| `get_sleuth_diagnose` | vmConnected / initialized |
| `get_sleuth_summary` | markdown 摘要 |
| `get_sleuth_route_health` | 路由健康分 |
| `get_perf_threshold_config` | 阈值与配置 |

### `skill_*`（flutter_skill 全量）

| 类别 | Tools |
|------|------|
| 检查 | `skill_interactive` / `_structured` / `skill_get_widget_tree` / `_properties` / `skill_get_text_content` / `skill_find_by_type` |
| 手势 | `skill_long_press` / `_double_tap` / `_drag` / `_press_key` / `_type_text` / `_focus` / `_blur` / `_set_checkbox` / `_hover` / `_tap_at` / `_long_press_at` / `_swipe_coordinates` / `_edge_swipe` / `_go_back` |
| 等待/表单 | `skill_wait_for_element` / `_gone` / `skill_get_text_value` / `_checkbox_state` / `_slider_value` |
| 截图 | `skill_screenshot` / `_region` / `_element` |
| 导航 | `skill_get_current_route` / `_navigation_stack` |
| 指示器/日志 | `skill_enable/disable_indicators` / `_get_indicator_status` / `skill_get_logs` / `_errors` / `_clear_logs` |
| 辅助指标 | `skill_get_performance` / `_frame_stats` / `_http_requests` / `_clear_http_requests`（主指标仍用 `get_sleuth_*`） |

> 性能走 **Sleuth 全量**（非 DevTools 外连）。flutter_skill 仍需 VM。  
> Bridge / MCP 响应统一 **`{ "code": 0, "data": ..., "msg": "ok" }`**（`code≠0` 为失败）。

## 文档

| 文档 | 内容 |
|------|------|
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | 接到业务 App |
| [docs/USAGE.md](docs/USAGE.md) | Cursor / 命令行用法 |
| [docs/DEMO.md](docs/DEMO.md) | Demo 脚本说明 |
| [docs/PHASE1.md](docs/PHASE1.md) · [PHASE2](docs/PHASE2.md) · [PHASE3](docs/PHASE3.md) | 里程碑 |
| [CHANGELOG.md](CHANGELOG.md) | 版本记录 |
| [PRD](../doc/Flutter-Perf-Agent.md) | 产品需求 |

## 注意

- 仅 Debug / Profile；Release 不启用
- 可信指标请用 `--profile`
- Android 模拟器需 `adb reverse tcp:19288 tcp:19288`
- 报告会标注采集工具额外开销
