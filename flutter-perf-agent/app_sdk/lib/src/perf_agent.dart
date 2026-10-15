import 'package:flutter/foundation.dart';
import 'package:flutter_skill/flutter_skill.dart';

import 'bridge_server.dart';

/// Entry point for embedding Flutter-Perf-Agent into a Flutter app.
class PerfAgent {
  static PerfBridgeServer? _bridge;
  static bool _initialized = false;

  static PerfBridgeServer? get bridge => _bridge;

  /// Initialize flutter-skill + local perf HTTP bridge.
  ///
  /// Call once before [runApp]. Wrap the app with `Sleuth.track(child: ...)`
  /// yourself so Sleuth owns the widget tree.
  static Future<void> ensureInitialized({
    String host = '127.0.0.1',
    int port = 19288,
    int waitStableMs = 500,
    bool enableFlutterSkill = true,
  }) async {
    if (_initialized) return;
    _initialized = true;

    if (kReleaseMode) {
      debugPrint('[PerfAgent] skipped in release mode');
      return;
    }

    if (enableFlutterSkill) {
      FlutterSkillBinding.ensureInitialized();
    }

    _bridge = PerfBridgeServer(
      host: host,
      port: port,
      waitStableMs: waitStableMs,
    );

    // Defer bind until after first frame so platform channels are ready.
    Future<void>.delayed(const Duration(milliseconds: 300), () async {
      try {
        await _bridge?.start();
      } catch (e, st) {
        debugPrint('[PerfAgent] bridge start failed: $e\n$st');
      }
    });
  }

  static Future<void> shutdown() async {
    await _bridge?.stop();
    _bridge = null;
    _initialized = false;
  }
}
