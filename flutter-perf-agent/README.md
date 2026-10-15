# Flutter-Perf-Agent

自然语言驱动 Flutter App：**UI 自动化 + 性能打点 + JSON/HTML 报告**。

**当前版本：V1（Phase3 完成）**

## 一句话架构

```
Cursor MCP
  ├─ flutter_skill（点击 / 输入 / 滑动 / 截图）
  └─ PerfBridge + Sleuth（会话 / 性能快照 / 告警）
```

## 目录

```
flutter-perf-agent/
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
| `start_perf_test` | 开会话（先清理旧会话） |
| `input_text` | 输入 + 性能 diff |
| `tap` | 点击 + 性能 diff（登录类自动加跳转等待） |
| `scroll` | 滑动 / 滚到目标 + 性能 diff |
| `stop_perf_test` | JSON + HTML（含截图） |
| `get_ui_snapshot` | 可交互控件 |
| `get_perf_threshold_config` | 阈值与稳定性配置 |

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
