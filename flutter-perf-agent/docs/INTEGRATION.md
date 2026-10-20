# 接入指南

把 Flutter-Perf-Agent 接到任意 Flutter 工程（仅 Debug / Profile）。

## 1. 依赖

```yaml
# pubspec.yaml
dependencies:
  flutter_perf_agent:
    path: /path/to/track/flutter-perf-agent/app_sdk
  sleuth: ^0.37.0
  flutter_skill: ^0.9.37   # 由 app_sdk 传递依赖，也可显式声明
```

```bash
flutter pub get
```

## 2. 初始化

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:sleuth/sleuth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kReleaseMode) {
    await PerfAgent.ensureInitialized(
      host: '127.0.0.1',
      port: 19288,
    );
  }

  runApp(
    Sleuth.track(
      child: const MyApp(),
      config: const SleuthConfig(fpsTarget: 60),
    ),
  );
}
```

## 3. 给控件加稳定定位

```dart
TextField(key: const Key('password_field'), ...)
FilledButton(
  key: const Key('login_button'),
  child: const Text('登录'),
)
// 或
Semantics(label: '登录按钮', button: true, child: ...)
```

MCP / flutter_skill 优先用 **Key** 或可见 **Text**；语义 label 作补充。

## 4. 配置 MCP（Cursor）

```json
{
  "mcpServers": {
    "flutter-perf-agent": {
      "command": "/path/to/dart",
      "args": [
        "/path/to/flutter-perf-agent/mcp_server/bin/server.dart",
        "--config",
        "/path/to/flutter-perf-agent/perf_agent_config.json"
      ]
    }
  }
}
```

重启 Cursor 后即可在对话里调用工具。

## 5. Android 模拟器注意

Bridge 绑在 App 内 `127.0.0.1`。宿主机访问模拟器内端口需：

```bash
adb reverse tcp:19288 tcp:19288
```

桌面（macOS）无需此步。

## 6. GetX / Navigator 自动 hook（0.8.3）

转场泄漏登记三选一（推荐 1）：

```dart
// 1) Binding：PerfDi（需配合 instrumentGetPages 注入路由 scope）
GetMaterialApp(
  getPages: PerfAgent.instrumentGetPages(AppPages.routes),
  navigatorObservers: PerfAgent.navigatorObservers,
);
// Binding.dependencies:
PerfDi.lazyPut(MyController.new);

// 2) mixin
class MyController extends GetxController with PerfLeakTrackMixin { ... }

// 3) 基类
class MyController extends PerfGetxController { ... }
```

`PerfDi` / mixin 默认 **不**在 `onClose` 从登记表摘掉（外部强引用仍可通过 WeakRef 检出）。长寿页可设 `leakUntrackOnClose => true` 降噪。

## 6.1 线上采样（0.8.7）

Release 默认仍 noop。需要线上轻量观测时：

```dart
await PerfAgent.ensureInitialized(
  leakOnlineEnabled: true,
  leakSampleRate: 0.01,
  onLeakOnlineEvent: (e) { /* 接宿主埋点 */ },
);
// navigatorObservers: PerfAgent.navigatorObservers
```

不启 Bridge / Sleuth / 截图。事件类型：`route_breadcrumb`、`transition_leak`。

## 7. 可信性能数据

```bash
flutter run --profile
```

Debug 只适合验流程；报告里会有采集开销说明。
