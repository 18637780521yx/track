# flutter_fast_track

轻量 Flutter **埋点上报** SDK（纯管道）：会话、批处理、ObjectBox 持久化、重试。

> **检测 / 崩溃 / ANR / jank / 网络 / 转场 / Bridge 不在本包。**  
> 请接 [`fast_track_mcp` App SDK](../fast_track_mcp/docs/INTEGRATION.md)。本包 `init` **零钩子**（无 `NavigatorObserver`、无 CrashHandler）。

## 能力

- **公共属性**：`registerCommonProperties` / `unregisterCommonProperties`
- **用户身份**：`identify(userId)` / `resetIdentity()`；匿名 ID 自动生成并持久化
- **隐私**：`setOptOut(true)` 停止采集（持久化）
- **Session**：前台可强制换新；超时默认 30min
- **持久化**：ObjectBox；批上报（默认间隔 15s、每批最多 100）
- **重试**：指数退避 + 429 `Retry-After`；冷却后继续，不丢已落库事件
- **去重**：每条 `event_id`（UUID v4）
- **干跑**：`dryRun: true` 只打日志不上报

## 安装

```yaml
dependencies:
  flutter_fast_track:
    path: ../fast_track   # 或 pub 版本
```

与性能检测一起用时，再加：

```yaml
  fast_track_mcp:
    path: ../fast_track_mcp/app_sdk
```

## 快速使用（仅上报）

```dart
import 'package:flutter_fast_track/flutter_fast_track.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FastTracker.init(
    url: 'http://127.0.0.1:8080/track',
    config: const TrackerConfig(
      flushInterval: Duration(seconds: 5),
      enableDebugLog: true,
      // dryRun: true, // 本地不连服务时
    ),
    initialCommonProperties: {'channel': 'dev'},
  );

  // 每次冷启换新 session（可选）
  FastTracker.tracker.onForeground();

  runApp(const MyApp());
}
```

### 上报事件

```dart
await FastTracker.track('page_view', properties: {'page': 'home'});
await FastTracker.tracker.flush(); // 可选，立即上报
```

### 用户身份

```dart
// 登录成功 / 冷启已登录
FastTracker.tracker.identify('user_12345');
FastTracker.tracker.registerCommonProperties({
  'lq_staff_name': '张三',
});

// 登出
FastTracker.tracker.resetIdentity();
```

### 公共属性

```dart
FastTracker.tracker.registerCommonProperties({
  'app_flavor': 'staging',
});
FastTracker.tracker.unregisterCommonProperties(['app_flavor']);
```

### 干跑

```dart
await FastTracker.init(
  url: 'http://127.0.0.1:8080/track',
  config: const TrackerConfig(dryRun: true, enableDebugLog: true),
);
```

### 自定义上传

```dart
await FastTracker.init(
  uploader: (events) async {
    await myCustomUpload(events);
    return const EventUploadResult.success();
  },
);
```

## 与 fast_track_mcp 一起用（推荐）

崩溃与检测由 MCP App SDK 负责，事件仍走 `FastTracker`：

```dart
import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';

Future<void> main() async {
  // 必须用 MCP 的 CrashHandler（本包已无 FastTrackCrashHandler）
  await FastTrackMcpCrashHandler.run(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 1) 先 FastTracker.init，再 MCP；否则检测事件只进预缓冲
    await FastTracker.init(url: 'http://127.0.0.1:8080/track', ...);

    if (!kReleaseMode) {
      await FastTrackMcp.ensureInitialized(host: '127.0.0.1', port: 19288);
    }

    runApp(...);

    if (!kReleaseMode) {
      FastTrackMcp.installHttpCaptureDeferred(
        excludeUrlSubstrings: const ['/track'],
      );
    }
  });
}
```

完整步骤见 [fast_track_mcp/docs/INTEGRATION.md](../fast_track_mcp/docs/INTEGRATION.md)。

## 本地验证

1. 起埋点服务：`track-server-py` → `http://127.0.0.1:8080`（`POST /track`）
2. 分析后台：`track-console` → `http://localhost:3000`（会话报告 `/reports`）
3. 真机：

```bash
adb reverse tcp:8080 tcp:8080
```

```bash
flutter run --dart-define=FAST_TRACK_URL=http://127.0.0.1:8080/track
```

## Release

| 项 | 说明 |
|----|------|
| 上报 | 配真实 `url`，勿长期 `dryRun` |
| 崩溃 | 用 `FastTrackMcpCrashHandler.run` 包住 `main`（见上） |
| Bridge / 抓包 / 手势 | Debug/Profile 由 MCP 开启；Release 默认关 |

## 注意

- `init` 传 **url** 或 **uploader** 二选一；服务端按 `event_id` 去重
- 重试用尽不丢事件，冷却后继续 flush
- `setOptOut(true)` 后 track/flush 均不执行
- 本包不再提供生命周期 / 页面自动埋点 / CrashHandler；这些在 `fast_track_mcp`
