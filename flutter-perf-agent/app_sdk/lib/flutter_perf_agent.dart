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

export 'src/perf_agent.dart';
export 'src/perf_snapshot.dart';
export 'src/bridge_server.dart';
export 'src/sleuth_facade.dart';
