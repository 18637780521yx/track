import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../detect/detect_sink.dart';
import '../network/network_capture.dart';

/// Records App 启动 / 进入后台 / 进入前台 → FastTrack 埋点。
///
/// Always keeps [lastEvent] for Bridge `/health` (MCP 可轮询).
class AppLifecycleTracker with WidgetsBindingObserver {
  AppLifecycleTracker._();
  static final AppLifecycleTracker instance = AppLifecycleTracker._();

  bool _started = false;
  DateTime? _backgroundedAt;
  bool _coldStartNoted = false;

  /// Latest lifecycle for Bridge health — independent of MCP automation.
  Map<String, dynamic>? lastEvent;

  /// MCP「可开始操作」：最近一次是启动或进前台（非后台）.
  bool get isForegroundish {
    final kind = lastEvent?['kind']?.toString();
    return kind == 'cold_start' || kind == 'foreground';
  }

  void ensureStarted() {
    if (kReleaseMode || _started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      noteColdStart(route: FastTrackMcpNetwork.currentRoute());
    });
  }

  void stop() {
    if (!_started) return;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
    _backgroundedAt = null;
  }

  /// Bridge up / first frame — kind=`cold_start`.
  void noteColdStart({String? route}) {
    if (_coldStartNoted) return;
    _coldStartNoted = true;
    _record(
      kind: 'cold_start',
      label: 'App 启动',
      route: route ?? FastTrackMcpNetwork.currentRoute(),
      at: DateTime.now(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final route = FastTrackMcpNetwork.currentRoute();
    final now = DateTime.now();

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt = now;
      _record(
        kind: 'background',
        label: 'App 进入后台',
        route: route,
        at: now,
      );
      return;
    }

    if (state == AppLifecycleState.resumed) {
      final bgAt = _backgroundedAt;
      final backgroundMs =
          bgAt == null ? null : now.difference(bgAt).inMilliseconds;
      _backgroundedAt = null;
      _record(
        kind: 'foreground',
        label: 'App 进入前台',
        route: route,
        at: now,
        backgroundMs: backgroundMs,
      );
    }
  }

  void _record({
    required String kind,
    required String label,
    required String? route,
    required DateTime at,
    int? backgroundMs,
  }) {
    lastEvent = {
      'kind': kind,
      'label': label,
      'at': at.toIso8601String(),
      if (route != null && route.isNotEmpty) 'route': route,
      if (backgroundMs != null) 'backgroundMs': backgroundMs,
    };
    debugPrint('[AppLifecycleTracker] $kind route=$route');

    FastTrackMcpDetectSink.track(
      'app_lifecycle',
      properties: {
        'kind': kind,
        'label': label,
        if (route != null && route.isNotEmpty) 'route': route,
        if (backgroundMs != null) 'background_ms': backgroundMs,
      },
    );
  }
}
