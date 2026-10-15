# Flutter-Perf-Agent（Phase 1 脚手架）

自然语言驱动 Flutter App UI 操作，并在每一步前后采集性能指标，输出 JSON 报告。

## 目录

```
flutter-perf-agent/
├── app_sdk/              # App 内嵌 SDK（Sleuth 打点 + HTTP Bridge）
├── mcp_server/           # Cursor MCP（start / stop / tap）
├── example_app/          # 登录 Demo
├── reports/              # JSON 报告输出
├── docs/
└── perf_agent_config.json
```

## Phase1 能力

**分工**：UI 动作 → `flutter_skill`；性能打点 → App Bridge + Sleuth；编排/报告 → 本 MCP。

| MCP Tool | 说明 |
|----------|------|
| `start_perf_test` | 开会话、记录 VM URI、读基线快照 |
| `tap` | flutter_skill 点击 + Bridge 前后性能 diff（失败可 legacy 回退） |
| `stop_perf_test` | 汇总告警并写 JSON 报告 |
| `get_ui_snapshot` | 可交互控件（优先 flutter_skill inspect） |
| `get_perf_threshold_config` | 阈值配置 |

## 快速开始

### 1. 依赖

```bash
cd app_sdk && flutter pub get
cd ../mcp_server && dart pub get
cd ../example_app && flutter pub get
```

### 2. 跑 Demo App（另开终端）

```bash
cd example_app
flutter run -d macos --profile
# 或 Android 模拟器：flutter run -d emulator-5554 --profile
```

启动后 Bridge 监听 `http://127.0.0.1:19288`。可用：

```bash
curl http://127.0.0.1:19288/health
```

### 3. 配置 Cursor MCP

项目已提供 `.cursor/mcp.json`。全局也可用：

```json
{
  "mcpServers": {
    "flutter-perf-agent": {
      "command": "dart",
      "args": [
        "run",
        "--working-directory",
        "/ABS/PATH/track/flutter-perf-agent/mcp_server",
        "bin/server.dart"
      ]
    }
  }
}
```

更稳妥写法（绝对路径）：

```json
{
  "mcpServers": {
    "flutter-perf-agent": {
      "command": "/Users/fc/fvm/default/bin/dart",
      "args": [
        "/ABS/PATH/track/flutter-perf-agent/mcp_server/bin/server.dart",
        "--config",
        "/ABS/PATH/track/flutter-perf-agent/perf_agent_config.json"
      ],
      "env": {
        "PATH": "/Users/fc/fvm/default/bin:/usr/bin:/bin"
      }
    }
  }
}
```

重启 Cursor 后，对 AI 说：

> 启动性能测试，名字：登录流程测试。点击「登录按钮」，然后停止测试并给出报告路径和告警。

（Demo 里密码为空会提示错误；可先点登录看 diff，或后续 Phase2 补 `input_text`。）

### 4. 不用 MCP 的手动冒烟

```bash
# 会话
curl -X POST http://127.0.0.1:19288/session/start \
  -H 'content-type: application/json' \
  -d '{"testName":"manual"}'

# 点击
curl -X POST http://127.0.0.1:19288/tap \
  -H 'content-type: application/json' \
  -d '{"targetDesc":"登录"}'
```

## 接入任意 Flutter App

```dart
import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:sleuth/sleuth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PerfAgent.ensureInitialized();
  runApp(Sleuth.track(child: const MyApp()));
}
```

`pubspec.yaml`：

```yaml
dependencies:
  flutter_perf_agent:
    path: ../flutter-perf-agent/app_sdk
  sleuth: ^0.37.0
```

给关键按钮加 `Semantics(label: '登录按钮')` 或稳定 `Key`。

## 注意

- 仅 Debug / Profile；Release 不启用。
- 可信性能数据请用 `--profile`。
- Bridge 默认绑定 `127.0.0.1`。Android 模拟器上 MCP 在宿主机时，需 `adb reverse tcp:19288 tcp:19288`，或把 host 改成 `0.0.0.0` 并经 adb forward（Phase1 优先 macOS / 桌面）。
- 报告会标注采集工具自身开销。

## Phase2 预留

- `scroll` / `input_text`
- HTML 报告
- 重试与更稳的页面稳定判定
