# 接入指南

把 Fast Track MCP 接到 Flutter 工程。

- **Debug / Profile**：检测 + Bridge + 抓包 + 手势（完整）
- **Release**：建议保留 `CrashHandler` + `FastTracker` 上报；Bridge / 抓包默认关

## 与 FastTrack 的分工

| 能力 | Owner |
|------|--------|
| 事件上传 / 批处理 / ObjectBox / identify | **`flutter_fast_track`**（`FastTracker`，零钩子） |
| Crash / Zone / 原生崩溃 / Tombstone | **`FastTrackMcpCrashHandler`** |
| ANR / jank / memory | **App SDK `detect/`**（`ensureInitialized` 内启动） |
| 转场账本 / 手势 / HTTP 抓包 / Bridge | **`FastTrackMcp`**（Debug/Profile） |
| 分析后台会话报告 | **`track-server-py` + `track-console`** |

冲突点：`HttpOverrides` 由 FastTrackMcp 独占（务必 `excludeUrlSubstrings` 排除 track URL）。不要再叠旧 Sleuth。

## 1. 依赖

```yaml
dependencies:
  flutter_fast_track:
    path: ../track/fast_track
  fast_track_mcp:
    path: ../track/fast_track_mcp/app_sdk
  flutter_skill: ^0.9.37   # Cursor MCP 手势需要；仅埋点也可保留
```

```bash
flutter pub get
```

## 2. 初始化（顺序不能反）

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';
import 'package:fast_track_mcp/fast_track_mcp.dart';

Future<void> main() async {
  // Release 也建议包住：崩溃 → app_crash → FastTracker
  await FastTrackMcpCrashHandler.run(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // ① 先上报管道
    await FastTracker.init(
      url: const String.fromEnvironment(
        'FAST_TRACK_URL',
        defaultValue: 'http://127.0.0.1:8080/track',
      ),
      config: TrackerConfig(
        dryRun: kReleaseMode && !const bool.fromEnvironment('TRACK_UPLOAD'),
        enableDebugLog: !kReleaseMode,
        flushInterval: const Duration(seconds: 5),
      ),
    );
    FastTracker.tracker.onForeground(); // 冷启换新 session（可选）

    // 已登录则立刻绑定，避免会话挂在「匿名」
    // FastTracker.tracker.identify(userId);

    // ② 再 MCP：Release 也调（只开 ANR/jank/memory，SDK 内不启 Bridge）
    await FastTrackMcp.ensureInitialized(
      host: '127.0.0.1',
      port: 19288,
      wireLeakOnlineToFastTrack: true,
      leakTrackEnabled: !kReleaseMode,
    );
    if (!kReleaseMode) {
      // Tab / 壳路由：把 /tabs 升成 /tabs#work
      FastTrackMcpNetwork.routeProvider = () => /* 你的逻辑路由 */ Get.currentRoute;
    }

    runApp(const MyApp());

    // ③ runApp 之后装 HTTP 抓包（仅 Debug/Profile）
    if (!kReleaseMode) {
      FastTrackMcp.installHttpCaptureDeferred(
        excludeUrlSubstrings: const ['/track'],
      );
    }
  });
}
```

### MaterialApp / GetX

```dart
GetMaterialApp(
  navigatorObservers: [
    ...FastTrackMcp.navigatorObservers, // Release 可传空列表
  ],
  getPages: FastTrackMcp.instrumentGetPages(AppPages.routes),
);
```

- **不要**再挂旧的 FastTrack NavigatorObserver（本包已无）。
- Bottom Tab：索引变更时调用 `TransitionLedger.instance.onLogicalChange(to, fromName: from)`，并在首屏 `seedShell('/tabs#work')`，避免转场 `from` 错乱。
- Binding 内推荐 `FastTrackMcpDi.lazyPut(...)` 做 WeakRef 泄漏跟踪。

### 用户身份

```dart
// 登录成功
FastTracker.tracker.identify('$userId');

// 退出
FastTracker.tracker.resetIdentity();
```

冷启若本地已有登录态，在 `FastTracker.init` 之后立刻 `identify`，否则会话报告会显示「匿名」。

## 3. 控件稳定定位（给 MCP 点选用）

```dart
TextField(key: const Key('password_field'), ...)
FilledButton(
  key: const Key('login_button'),
  child: const Text('登录'),
)
```

优先 **Key** / 可见 **Text**；`Semantics` 作补充。

## 4. 本地联调

```bash
# 埋点服务
cd track/track-server-py && python -m app.main   # :8080

# 分析后台
cd track/track-console && npm run dev            # :3000 → /reports

# 真机 USB
adb reverse tcp:8080 tcp:8080
adb reverse tcp:19288 tcp:19288
```

未做 `adb reverse` 时，App 访问 `127.0.0.1:8080` 会连续 `retry code=null`。

## 5. Cursor MCP（可选）

```json
{
  "mcpServers": {
    "fast_track_mcp": {
      "command": "dart",
      "args": [
        "C:/path/to/track/fast_track_mcp/mcp_server/bin/server.dart",
        "--config",
        "C:/path/to/track/fast_track_mcp/perf_agent_config.json"
      ]
    }
  }
}
```

重启 Cursor。用法见 [USAGE.md](USAGE.md)。`get_sleuth_*` 已下线。

## 6. Release

| 做 | 不做（默认） |
|----|----------------|
| `FastTrackMcpCrashHandler.run` | **Bridge `:19288`** |
| `FastTracker.init`（**生产 URL**，勿 dryRun） | MCP 自动化 / flutter_skill |
| ANR / jank / memory | 全量 WeakRef（可用 `leakOnlineEnabled` 采样） |
| 手势 `ui_tap` / `ui_scroll` | |
| Tab / 路由转场账本（`releaseUiHooks=true`） | |
| HTTP 抓包：`allowInRelease` + **`captureBodyOnFailureOnly`**（成功无 body，失败才带） | |

```dart
FastTrackMcp.releaseUiHooks = true;
ManualGestureRecorder.instance.ensureStarted();
FastTrackMcp.installHttpCaptureDeferred(
  allowInRelease: true,
  captureBodyOnFailureOnly: true, // 仅失败带 body
  maxBodyBytes: 32 * 1024,
  excludeUrlSubstrings: const ['/track'],
);
```

未配 `FAST_TRACK_URL` 时 Release 仍可能 `dryRun`——监控事件会记但发不出去。

## 参考实现

业务侧可参考 `lianqiaoapp/lib/app/perf/perf_bootstrap.dart`（Tracker → MCP → Tab 路由 → identify）。

## 异常采集行为

- `run()` 在同一 Zone 中初始化 Binding 并执行启动回调；启动异常上报后，返回的 Future 正常结束。后续异步回调仍受 Zone 保护。
- Flutter 框架错误记为非致命 `app_error`；Zone、Platform、Isolate 未捕获错误记为 `app_crash`。手动上报可通过 `fatal` 指定。
- MCP 初始化 `flutter_skill` 时会保留原有 `FlutterError.onError`：同一错误同时进入自动化错误列表和 FastTracker。修复初始化钩子后需完整重启 App，仅热重载不会重新安装处理器。
- 原生崩溃先落盘，成功写入 FastTracker 本地队列后才确认删除；初始化或入队失败时保留，下次启动重试。重复回捞使用相同事件 ID。
- `FastTrackMcp.ensureInitialized()` 会在 FastTracker 初始化后重试原生启动；仅使用捕获器时，可在 `FastTracker.init()` 后调用 `FastTrackMcpCrashHandler.ensureNativeInitialized()`。
- 新采集的原生异常保留发生时间和启动时同步的会话 ID。系统历史诊断、旧版记录没有原会话时使用 `native-recovered`，不归入本次启动会话；MetricKit 的时间是诊断窗口结束时间。

本仓库开发需使用配套的 `fast_track` 源码（`pubspec_overrides.yaml`），其中新增了可靠入队接口 `FastTracker.persistCrash()`；发布 App SDK 前须先发布并更新该依赖版本。

## 性能监控的判定与回捞

- iOS Hang 仅检查前台、正在处理任务的 RunLoop；正常等待事件与后台状态不计为卡死。耗时使用单调时钟，停止或切换前后台后不会投递旧告警。
- Android 历史 ANR 逐条落盘并携带稳定 ID。Dart 成功持久化后才调用 `ackAnr`；失败保留待重试，历史事件不受实时告警冷却限制。系统记录没有原会话时使用 `native-recovered`，发生时间使用系统退出时间。
- 卡顿预算默认跟随屏幕刷新率，也可通过 `jankFpsTarget` 手动指定。`slow_frames` / `jank_rate` 按 build 或 raster 超预算统计；`high_latency_frames` 单独记录总延迟。`severity: latency` 不代表处理阶段掉帧。
- 卡顿报告发送繁忙时合并待发送窗口，保留帧数、峰值和加权平均值。即时 frozen 事件和聚合窗口是同一帧的两种视图，统计时不要相加。
- 内存增长与内存压力分别冷却，压力升级不会被普通增长告警阻挡；RSS 增长仍是启发式信号，不证明对象泄漏。
- Debug/Profile/Release 统一应用 `leakTrackEnabled`、`alertOnWeakRef` 和 `requireMultiRound`。默认 `requireMultiRound: true`；线上转场上报也遵循该策略。
- 泄漏探测按完整路由匹配，不混用不同 `#` 后缀。WeakReference 存活仅表示疑似滞留，输出 `severity: leak_suspect`、`gc_verified: false`；多轮确认仍不等于 GC 根因验证。需要精确区分同一路径的多个页面时，宿主应使用不同路由标识。
