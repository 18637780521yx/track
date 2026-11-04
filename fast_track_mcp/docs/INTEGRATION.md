# 接入指南

把 Fast Track MCP 接到任意 Flutter 工程。开发账本以 Debug / Profile 为主；Release 仅可选 LeakOnline。

## 与 FastTrack 的分工（避免冲突）

| 能力 | Owner |
|------|--------|
| Dart Crash / Zone / `FlutterError` / Isolate / jank / RSS | **FastTrackMcp App SDK**（`detect/`）→ Journal + 可选 `FastTracker.track` |
| 原生 Crash / Tombstone | **同插件**：Android Uncaught + ExitInfo(+trace tombstone) + 可读时 `/data/tombstones`；iOS Uncaught + pending + **MetricKit**（14+） |
| ANR / App Hang | **原生插件**（Android Watchdog + ExitInfo ANR / iOS RunLoop）；非移动端 Soft Isolate 回退 |
| SessionJournal / Bridge / MCP / 手势 / 全量 HTTP / WeakRef 转场 | **FastTrackMcp**（dev） |
| 事件上传 / 批处理 / ObjectBox | **FastTrack**（`FastTracker`，仅 track，无 NavigatorObserver、无自建检测） |

真冲突点：`HttpOverrides` 由 FastTrackMcp 独占（排除 track 上报 URL）。勿再叠 Sleuth。

## 1. 依赖

```yaml
# pubspec.yaml
dependencies:
  fast_track_mcp:
    path: /path/to/track/fast_track_mcp/app_sdk
  flutter_fast_track:
    path: /path/to/track/fast_track
  flutter_skill: ^0.9.37   # MCP 手势需要
```

```bash
flutter pub get
```

## 2. 初始化

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';
import 'package:fast_track_mcp/fast_track_mcp.dart';

Future<void> main() async {
  await FastTrackMcpCrashHandler.run(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await FastTracker.init(
      url: 'https://your-track-server/v1/events',
      config: const TrackerConfig(dryRun: true), // 或生产 URL
    );

    if (!kReleaseMode) {
      await FastTrackMcp.ensureInitialized(
        host: '127.0.0.1',
        port: 19288,
        wireLeakOnlineToFastTrack: true,
      );
    }

    runApp(const MyApp());

    if (!kReleaseMode) {
      FastTrackMcp.installHttpCaptureDeferred();
    }
  });
}
```

`navigatorObservers` 挂：`FastTrackMcp.navigatorObservers`（含转场 / 生命周期；**不要**再挂 FastTrack 的 NavigatorObserver）。

GetX：`FastTrackMcp.instrumentGetPages(...)` + `FastTrackMcpDi.lazyPut` 自动 WeakRef。

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
    "fast_track_mcp": {
      "command": "/path/to/dart",
      "args": [
        "/path/to/fast_track_mcp/mcp_server/bin/server.dart",
        "--config",
        "/path/to/fast_track_mcp/perf_agent_config.json"
      ]
    }
  }
}
```

重启 Cursor 后即可在对话里调用工具。`get_sleuth_*` 已下线；看告警用会话报告 / Bridge snapshot。

## 5. Android 模拟器注意

Bridge 绑在 App 内 `127.0.0.1`。宿主机访问模拟器内端口需：

```bash
adb reverse tcp:19288 tcp:19288
```

## 6. Release LeakOnline（可选）

不启 Bridge。事件类型：`route_breadcrumb`、`transition_leak`。见 `ensureInitialized(leakOnlineEnabled: true, …)`。
