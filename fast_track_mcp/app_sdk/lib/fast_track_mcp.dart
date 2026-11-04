/// Fast Track MCP App SDK — 检测 + 会话账本 + Bridge；上报走 [flutter_fast_track]。
///
/// ```dart
/// void main() {
///   FastTrackMcpCrashHandler.run(() async {
///     WidgetsFlutterBinding.ensureInitialized();
///     await FastTracker.init(url: '...'); // 仅上报，零钩子
///     await FastTrackMcp.ensureInitialized(); // crash/ANR/jank/memory + Bridge
///     runApp(const MyApp());
///     FastTrackMcp.installHttpCaptureDeferred();
///   });
/// }
/// ```
///
/// 源码按域分目录：`agent` / `bridge` / `detect` / `gesture` / `leak` /
/// `lifecycle` / `network` / `session` / `tools`。
library;

export 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';

// agent
export 'src/agent/mcp_agent.dart';
export 'src/agent/fast_track_bridge.dart';

// bridge
export 'src/bridge/bridge_discovery.dart';
export 'src/bridge/bridge_server.dart';

// detect
export 'src/detect/anr_watchdog.dart';
export 'src/detect/crash_capture.dart';
export 'src/detect/crash_handler.dart';
export 'src/detect/event_names.dart';
export 'src/detect/jank_monitor.dart';
export 'src/detect/memory_monitor.dart';

// gesture
export 'src/gesture/hit_target.dart';
export 'src/gesture/manual_gesture_recorder.dart';
export 'src/gesture/recording_overlay.dart';

// leak
export 'src/leak/getx_leak_hook.dart';
export 'src/leak/leak_online.dart';
export 'src/leak/transition_leak_tracker.dart';
export 'src/leak/transition_ledger.dart';

// network
export 'src/network/network_capture.dart';

// session
export 'src/session/perf_snapshot.dart';
export 'src/session/reports_path.dart';
export 'src/session/sdk_report_writer.dart';
export 'src/session/session_journal.dart';

// tools
export 'src/tools/screenshot_tool.dart';
