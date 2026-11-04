# flutter_fast_track

轻量级 Flutter 埋点 SDK，支持：

- **公共属性**：register / unregister，每条事件自动带上
- **用户身份**：`identify(userId)` / `resetIdentity()`，匿名 ID 自动生成并持久化
- **隐私合规**：`setOptOut(true)` 停止采集，状态持久化
- **Session**：前台重置 + 超时可配置（默认 30min）
- **高性能持久化**：ObjectBox 存储（比 SharedPreferences 快 10 倍），单一数据源架构
- **批量上报**：与神策一致（flush_interval 15s、每批最多 100 条）；定时 + 满批触发
- **智能重试**：指数退避 + 429 Retry-After 支持；重试用尽不丢事件，进入 30min 冷却后再试
- **网络感知**：flush 前检查网络状态，无网时跳过（事件保留在队列中）
- **去重**：每条事件带唯一 UUID v4，服务端按 `event_id` 去重重试幂等
- **自动属性**：设备/应用/网络（依赖 `fast_tools`）
- **自动埋点**：启动 / 前后台 / 首开 / 日活 / 页面曝光与停留 / 崩溃（含异常时自动 flush） / ANR（UI Isolate 卡死） / 卡顿掉帧（FrameTiming） / 内存泄漏启发式（RSS）
- **Debug 干跑**：`dryRun: true` 只记录日志不实际上传，开发阶段验证埋点
- **可插拔上传**：支持自定义 `EventUploader`，可对接非 HTTP 通道
- **Flush 回调**：`onFlushResult` 监控上传统计

## 安装

```yaml
dependencies:
  flutter_fast_track: ^0.1.0
```

## 快速使用

```dart
import 'package:flutter_fast_track/flutter_fast_track.dart';

Future<void> main() async {
  await FastTrackCrashHandler.run(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await FastTracker.init(
      url: 'https://api.example.com/track',
      config: const FastEventTrackerConfig(
        maxBatchSize: 100,
        flushInterval: Duration(seconds: 15),
        enableDebugLog: true,
      ),
      initialCommonProperties: {'channel': 'app_store'},
    );

    final lifecycleObserver = FastTrackLifecycleObserver();
    final navigatorObserver = FastTrackNavigatorObserver();
    runApp(MyApp(navigatorObserver: navigatorObserver));
    // 生命周期：首帧后 start() 即可，内部 addObserver 到 WidgetsBinding
    WidgetsBinding.instance.addPostFrameCallback((_) => lifecycleObserver.start());
  });
}

// 页面曝光：需把 navigatorObserver 挂到 MaterialApp 的 navigatorObservers
```

### 公共属性

```dart
FastEventTracker.tracker.registerCommonProperties({
  'app_version': '1.0.0',
  'channel': 'app_store',
});
FastEventTracker.tracker.unregisterCommonProperties(['channel']);
```

### 用户身份

```dart
// 登录后绑定用户 ID
FastEventTracker.tracker.identify('user_12345');

// 登出时重置（清除 distinctId，生成新 anonymousId）
FastEventTracker.tracker.resetIdentity();
```

### 隐私合规

```dart
// 用户拒绝数据采集时
FastEventTracker.tracker.setOptOut(true);  // track() 和 flush() 均不执行，状态持久化

// 用户重新同意
FastEventTracker.tracker.setOptOut(false);
```

### 上报事件

```dart
FastEventTracker.track('page_view', properties: {'page': 'home'});
await FastEventTracker.tracker.flush(); // 可选，立即上报
```

### Debug 干跑模式

```dart
await FastTracker.init(
  url: 'https://api.example.com/track',
  config: const FastEventTrackerConfig(
    dryRun: true,        // 只打日志不真正上传
    enableDebugLog: true,
  ),
);
```

### 自定义上传通道

```dart
await FastTracker.init(
  uploader: (events, [options]) async {
    // 自定义上传逻辑（如 gRPC、WebSocket 等）
    await myCustomUpload(events);
    return const EventUploadResult.success();
  },
);
```

### 自动埋点

| 来源 | 事件 | 说明 |
|------|------|------|
| `FastTrackLifecycleObserver.start()` | `app_start` | 每次启动 |
| | `app_first_open` | 首次安装后第一次启动 |
| | `app_daily_active` | 当日首次进入前台 |
| | `app_foreground` / `app_background` | 切前后台 |
| | `app_session` | 属性 `duration_ms` |
| `FastTrackNavigatorObserver` 挂到 MaterialApp | `page_view` | 属性 `page_name`、`from_page` |
| | `page_stay` | 属性 `page_name`、`duration_ms` |
| `FastTrackCrashHandler.run()` 包住 `ensureInitialized` 和 `runApp` | `app_crash` | 未捕获异常。来源 `type`：`flutter_error`（框架）、`zone_error`（当前 Zone）、`platform_error`（`PlatformDispatcher`）、`isolate_error`（当前 Isolate 或 `isolateErrorPort`）。属性含 `exception_type`、`message`、`stack`、`thread`、`is_fatal`，并保留 `exception`。捕获后立即 flush |
| `FastTrackCrashHandler.captureException` / `captureMessage` | `app_error` | 已经 catch 住仍要上报。`captureException(..., fatal: true)` 记 `app_crash` |
| `FastTracker.init`（`enableAnrWatchdog: true`，默认开） | `app_anr` | 后台 Isolate ping UI；超过 `anrTimeout`（默认 5s）未 ack 则上报。属性含 `blocked_ms`、`anr_source`、`exception_type=ApplicationNotResponding`、`is_fatal=false`。卡死期间消息排队，**UI 恢复后**再落库并 flush。Dart 无法 dump 对端堆栈，`stack` 可能为空 |
| `FastTracker.init`（`enableJankMonitor: true`，默认开） | `app_jank` | `FrameTiming`：超过帧预算为 slow，≥`jankFrozenFrameThreshold`（默认 700ms）为 frozen。窗口聚合（默认 10s，至少 3 个慢帧）打 `type=frame_window`；冻帧立即打 `type=frozen_frame` 并 flush。属性含 `slow_frames` / `frozen_frames` / `max_total_ms` / `jank_rate` 等。走业务 `events` 表，不是稳定性表 |
| `FastTracker.init`（`enableMemoryMonitor: true`，默认开） | `app_memory_leak` | 定期采 `ProcessInfo.currentRss`。连续 N 次上涨（默认 5 段、每次 ≥2MiB）→ `type=memory_growth`；超过水位（默认 512MiB）→ `type=memory_pressure`。带上报冷却（默认 5min）。**启发式**，不是对象级泄漏定位 |

```dart
await FastTracker.init(
  url: 'https://api.example.com/track',
  config: const TrackerConfig(
    enableAnrWatchdog: true, // 默认 true
    anrTimeout: Duration(seconds: 5),
    enableJankMonitor: true, // 默认 true
    jankFpsTarget: 60,
    jankReportInterval: Duration(seconds: 10),
    jankFrozenFrameThreshold: Duration(milliseconds: 700),
    enableMemoryMonitor: true, // 默认 true
    memorySampleInterval: Duration(seconds: 30),
    memoryGrowthStreak: 5,
    memoryMinGrowthBytes: 2 * 1024 * 1024,
    memoryPressureBytes: 512 * 1024 * 1024,
  ),
);
```

> Debug 包本身偏慢，`app_jank` 可能偏多；线上看 release/profile 更准。可按需关掉 `enableJankMonitor`。  
> `app_memory_leak` 只说明 RSS 异常上涨/触顶，不能指出是哪个对象泄漏；要根因请用 DevTools / flutter-perf-agent。

## 本地验证

1. **起本地服务**（终端一）：
   ```bash
   dart run tool/serve_track.dart
   ```
   默认 `http://0.0.0.0:8080`，支持本机与模拟器/真机访问。

2. **跑 example**（终端二）：
   ```bash
   cd example && flutter run
   ```
   example 在 main 中已 init，启动即打 `app_start` / 首开 / 日活；可点「打开详情页」测 page_view / page_stay，「触发异常」测 app_crash，「立即 flush」看服务端日志。

   **模拟器/真机**：需用电脑局域网 IP，例如：
   ```bash
   flutter run --dart-define=TRACK_HOST=192.168.1.100
   ```

## 架构特点

### 高性能持久化
- 使用 **ObjectBox** 作为唯一数据源（Single Source of Truth）
- 比 SharedPreferences 快 **10 倍**（增量写入，无需序列化整个队列）
- 事务机制保证数据一致性，崩溃不丢数据
- 无界队列，不受 `maxCachedEvents` 限制

### 唯一 ID 生成
- 使用 **UUID v4** 生成全局唯一事件 ID
- 符合业界标准（Mixpanel `$insert_id`、Segment `messageId`）
- 服务端按 `event_id` 去重，实现重试幂等

## 注意

- init 传 **url**（使用内置 Dio 上传）或 **uploader**（自定义上传），二选一。服务端需按 **event_id** 去重（如 7 天内已处理则丢弃），实现重试幂等。
- 重试用尽后**不丢事件**，进入冷却（默认 30min），下次 flush 再试；事件持久化在 ObjectBox 中，不会丢失。
- 429 限流响应支持 `Retry-After` 头，SDK 自动遵守服务端要求的等待时间。
- `setOptOut(true)` 后 track/flush 均不执行，状态持久化（重启仍生效），恢复需 `setOptOut(false)`。
- 崩溃时会在打 `app_crash` 后立即 flush 一次。事件先写入 ObjectBox，进程若在写入完成前退出仍可能丢这一次；下次启动会补发已落库的事件。
- `ensureInitialized()` 要写在 `FastTrackCrashHandler.run()` 回调里，和 `runApp` 同一个 Zone。
- 子 Isolate：`Isolate.spawn(entry, message, onError: FastTrackCrashHandler.isolateErrorPort)`。
- 已捕获异常：`FastTrackCrashHandler.captureException(error, stackTrace: stack)`，对应 `app_error`。

