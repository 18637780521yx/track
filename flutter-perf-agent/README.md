# Flutter-Perf-Agent

自然语言驱动 Flutter App UI 操作，并在每一步前后采集性能指标，输出 **JSON + HTML** 报告。

当前进度：**Phase2**

## 目录

```
flutter-perf-agent/
├── app_sdk/              # App 内嵌 SDK（Sleuth 打点 + HTTP Bridge）
├── mcp_server/           # Cursor MCP
├── example_app/          # 登录 → 列表 Demo
├── reports/              # JSON / HTML 报告
├── docs/
└── perf_agent_config.json
```

## 架构

```
Cursor
  └─ flutter-perf-agent MCP
        ├─ UI：flutter_skill（tap / input_text / scroll）
        └─ 性能：HTTP PerfBridge（session / snapshot / wait）
              └─ Sleuth + RSS
```

## MCP 工具

| Tool | 说明 |
|------|------|
| `start_perf_test` | 开会话、记录 VM URI、基线快照 |
| `input_text` | 输入文字 + 性能 diff |
| `tap` | 点击 + 性能 diff（可 legacy 回退） |
| `scroll` | 滑动 / 滚到目标 + 性能 diff |
| `stop_perf_test` | 写 JSON + HTML 报告 |
| `get_ui_snapshot` | 可交互控件 |
| `get_perf_threshold_config` | 阈值与重试配置 |

## 快速开始

```bash
cd app_sdk && flutter pub get
cd ../mcp_server && dart pub get
cd ../example_app && flutter pub get

# 终端1
cd example_app && flutter run -d macos --profile

# 探活
curl http://127.0.0.1:19288/health
```

Cursor MCP（已可写在 `~/.cursor/mcp.json` 或本目录 `.cursor/mcp.json`）：

```json
{
  "mcpServers": {
    "flutter-perf-agent": {
      "command": "/Users/fc/fvm/default/bin/dart",
      "args": [
        "/ABS/PATH/track/flutter-perf-agent/mcp_server/bin/server.dart",
        "--config",
        "/ABS/PATH/track/flutter-perf-agent/perf_agent_config.json"
      ]
    }
  }
}
```

对 AI 说：

> 启动性能测试「登录到列表滑动」：密码框输入 123456，点登录，向下滑两次，停止并给报告路径。

## 接入业务 App

```dart
await PerfAgent.ensureInitialized();
runApp(Sleuth.track(child: const MyApp()));
```

```yaml
dependencies:
  flutter_perf_agent:
    path: ../flutter-perf-agent/app_sdk
  sleuth: ^0.37.0
```

关键控件加稳定 `Key` / `Semantics(label: ...)`。

## 文档

- [Phase1](docs/PHASE1.md)
- [Phase2](docs/PHASE2.md)
- [PRD](../doc/Flutter-Perf-Agent.md)
