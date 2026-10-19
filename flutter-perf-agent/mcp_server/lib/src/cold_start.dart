import 'dart:io' as io;

import 'bridge_client.dart';
import 'config.dart';

/// Kill + relaunch a macOS Flutter `.app` and wait until PerfBridge is ready.
class ColdStartLauncher {
  ColdStartLauncher({
    required this.config,
    required this.bridge,
    void Function(String msg)? log,
  }) : _log = log ?? ((_) {});

  final PerfAgentConfig config;
  final BridgeClient bridge;
  final void Function(String msg) _log;

  /// Returns wall-clock ms from process launch until bridge+route are ready.
  Future<int> relaunchAndWait() async {
    final appPath = config.resolveColdStartAppPath();
    if (appPath == null) {
      throw StateError('coldStart.appPath is not configured');
    }
    final app = io.Directory(appPath);
    if (!await app.exists()) {
      throw StateError('coldStart app not found: $appPath');
    }

    _log('cold_start kill existing example_app');
    await io.Process.run('pkill', ['-f', 'example_app.app']);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    _log('cold_start open $appPath');
    final t0 = DateTime.now();
    final opened = await io.Process.run('open', [appPath]);
    if (opened.exitCode != 0) {
      throw StateError(
        'open failed (${opened.exitCode}): ${opened.stderr}',
      );
    }

    final deadline = t0.add(Duration(milliseconds: config.coldStartMaxWaitMs));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await bridge.ensureResolved(force: true);
        final health = await bridge.health();
        if (health.isOk && health.data?.vmServiceUri != null) {
          final route = await bridge.appRoute();
          if (route.isOk &&
              (route.data?.route.trim().isNotEmpty ?? false)) {
            final ms = DateTime.now().difference(t0).inMilliseconds;
            _log('cold_start ready in ${ms}ms route=${route.data!.route}');
            return ms;
          }
        }
      } catch (e) {
        _log('cold_start wait: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw TimeoutException(
      'cold start timed out after ${config.coldStartMaxWaitMs}ms',
    );
  }
}

class TimeoutException implements Exception {
  TimeoutException(this.message);
  final String message;
  @override
  String toString() => message;
}
