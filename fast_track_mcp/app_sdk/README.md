# fast_track_mcp

Flutter **性能检测 + Bridge** App SDK。事件上报走 [`flutter_fast_track`](https://pub.dev/packages/flutter_fast_track)。

## 能力

- Crash / Zone / 原生崩溃 / Tombstone
- ANR / App Hang、jank、memory
- 转场账本、手势、HTTP 抓包
- Bridge `:19288`（Debug/Profile；给 Cursor MCP / curl）

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

    if (!kReleaseMode) {
      FastTrackMcp.installHttpCaptureDeferred(
        excludeUrlSubstrings: const ['/track'],
      );
    }
  });
}
```

完整接入见仓库 [docs/INTEGRATION.md](https://github.com/18637780521yx/track/blob/main/fast_track_mcp/docs/INTEGRATION.md)。

## License

MIT
