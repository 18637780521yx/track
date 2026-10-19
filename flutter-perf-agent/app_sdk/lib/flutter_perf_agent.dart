/// Flutter-Perf-Agent App SDK (Phase 1).
///
/// Embed in the app under test:
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized();
///   PerfAgent.ensureInitialized();
///   runApp(Sleuth.track(child: const MyApp()));
/// }
/// ```
library;

export 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

export 'src/perf_agent.dart';
export 'src/perf_snapshot.dart';
export 'src/bridge_discovery.dart';
export 'src/bridge_server.dart';
export 'src/network_capture.dart';
export 'src/sleuth_facade.dart';
export 'src/session_journal.dart';
export 'src/manual_gesture_recorder.dart';
export 'src/hit_target.dart';
export 'src/sdk_report_writer.dart';
export 'src/recording_overlay.dart';
