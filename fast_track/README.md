# fast_track

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
- **自动埋点**：启动 / 前后台 / 首开 / 日活 / 页面曝光与停留 / 崩溃（含异常时自动 flush）
- **Debug 干跑**：`dryRun: true` 只记录日志不实际上传，开发阶段验证埋点
- **可插拔上传**：支持自定义 `EventUploader`，可对接非 HTTP 通道
- **Flush 回调**：`onFlushResult` 监控上传统计

## 安装

```yaml
dependencies:
  fast_track:
    path: ../fast_track
  fast_tools:
    path: ../fast_utils  # 或你的 fast_tools 路径
  dio: ^5.0.0
```

## 快速使用

```dart
import 'package:fast_track/fast_track.dart';

Future<void> main() async {
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

  await FastTrackCrashHandler.run(() async {
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
| `FastTrackCrashHandler.run()` 包住 runApp | `app_crash` | FlutterError / Zone 未捕获异常，属性含 `type`、`exception`、`stack`；捕获后会自动 flush 一次尽量上报 |

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
- 崩溃时会在打 `app_crash` 后立即 flush 一次，进程若很快退出仍可能发不出去，建议配合定时 flush 与持久化。

