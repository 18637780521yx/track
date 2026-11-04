/// Fast Track MCP App SDK — 检测 + Bridge；上报走 [flutter_fast_track]。
///
/// ```dart
/// void main() {
///   FastTrackMcpCrashHandler.run(() async {
///     WidgetsFlutterBinding.ensureInitialized();
///     await FastTracker.init(url: '...');
///     await FastTrackMcp.ensureInitialized();
///     runApp(const MyApp());
///     FastTrackMcp.installHttpCaptureDeferred();
///   });
/// }
/// ```
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
export 'src/detect/crash_handler.dart';
export 'src/detect/event_names.dart';
export 'src/detect/jank_monitor.dart';
export 'src/detect/memory_monitor.dart';

// gesture
export 'src/gesture/hit_target.dart';
export 'src/gesture/manual_gesture_recorder.dart';

// lifecycle
export 'src/lifecycle/app_lifecycle_tracker.dart';
export 'src/lifecycle/cold_start_clock.dart';

// leak
export 'src/leak/getx_leak_hook.dart';
export 'src/leak/leak_online.dart';
export 'src/leak/transition_leak_tracker.dart';
export 'src/leak/transition_ledger.dart';

// network
export 'src/network/network_capture.dart';

// session
export 'src/session/perf_snapshot.dart';

// tools
export 'src/tools/screenshot_tool.dart';
