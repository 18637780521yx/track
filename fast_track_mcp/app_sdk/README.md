# fast_track_mcp

Flutter **性能检测 + Bridge** App SDK。事件上报走 [`flutter_fast_track`](https://pub.dev/packages/flutter_fast_track)。

## 能力

- Crash / Zone / 原生崩溃 / Tombstone
- ANR / App Hang、jank、memory
- 转场账本、手势、HTTP 抓包
- Bridge `:19288`（Debug/Profile；给 Cursor MCP / curl）

内存检测包含 RSS 窗口趋势、多次超预算检查，以及 Debug/Profile 的 VM 堆 / GC / 异步资源证据。
趋势不等于泄漏，详细规则与配置见 [内存监测说明](../../doc/memory-monitoring.md)。

## Install

```yaml
dependencies:
  flutter_fast_track: ^0.2.0
  fast_track_mcp: ^0.10.0
```

## Quick start

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';
import 'package:fast_track_mcp/fast_track_mcp.dart';

Future<void> main() async {
  await FastTrackMcpCrashHandler.run(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await FastTracker.init(
      url: 'https://api.example.com/track',
      config: TrackerConfig(
        enableDebugLog: !kReleaseMode,
      ),
    );

    await FastTrackMcp.ensureInitialized(
      host: '127.0.0.1',
      port: 19288,
    );

    runApp(const MyApp());


  });
}
```

## 网络请求上报（按需接入）

SDK 默认只提供上报接口，不新增 Dio 依赖。由业务采集参数、请求头和耗时，并按自己的规则判断 HTTP 失败或业务失败。例如 HTTP 200 返回业务错误时：

```dart
FastTrackMcpNetwork.record(NetworkRequest(
  url: 'https://api.example.com/order?id=123',
  method: 'POST',
  statusCode: 200,
  durationMs: 120,
  responseBytes: 0, // 未知时填 0，不要为了测量而读取响应流
  startedAt: startedAt.toUtc().toIso8601String(),
  source: 'manual',
  requestHeaders: {'content-type': 'application/json'},
  requestBody: '{"id":123}',
  businessSuccess: false, // 由业务判断，不从 HTTP 200 推断
  businessCode: 'OUT_OF_STOCK',
  businessMessage: '库存不足',
  responseBody: '{"code":"OUT_OF_STOCK","message":"库存不足"}',
));
```

Debug/Profile/Release 都可以调用。URL 查询参数放在 `url`，请求参数序列化为 `requestBody`，请求头放在 `requestHeaders`。仅失败时传 `responseBody`，成功时不传；SDK 按传入内容记录，不会自行读取、脱敏或截断。业务应限制内容长度，并用 `requestBodyTruncated` / `responseBodyTruncated` 标记截断，不传文件或响应流。

`businessSuccess` 不传表示未判断业务结果；传 `false` 可记录 HTTP 200 下的业务失败，并产生 `perf_business_error` 指标。HTTP/连接错误可通过 `error` 和 `flags: ['http_error']` / `['client_error']` 标记。所有记录复用普通埋点缓存和批量上传策略。由接入方过滤 SDK 自身上传请求，避免循环上报；每次请求只上报一次。

完整接入见仓库 [docs/INTEGRATION.md](https://github.com/18637780521yx/track/blob/main/fast_track_mcp/docs/INTEGRATION.md)。

调试时可在首次初始化打开原来的全局 HTTP 抓包：

```dart
await FastTrackMcp.ensureInitialized(enableHttpCapture: true);
```

`enableHttpCapture` 默认 `false`，只在 Debug/Profile 生效，Release 始终不安装全局抓包。开关启用后记录请求头、请求 body 和响应 body（包括 HTTP 200）；仅能识别 HTTP/客户端错误，HTTP 200 的业务失败仍需业务通过 `record` 上报。请勿对同一个请求同时自动抓包和手动上报。开关用于首次初始化，修改后需重启应用；已创建的 HTTP 客户端需重新创建才能被代理。

## License

MIT
