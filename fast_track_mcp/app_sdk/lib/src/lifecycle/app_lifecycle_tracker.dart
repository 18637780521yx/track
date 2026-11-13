import 'dart:async';

import 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../detect/detect_sink.dart';
import '../leak/transition_ledger.dart';
import '../network/network_capture.dart';
import 'cold_start_clock.dart';

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
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final clock = ColdStartClock.instance;
    clock.start();
    unawaited(clock.firstFrameReady.then((_) => _emitColdStartWhenReady()));
  }

  void stop() {
    if (!_started) return;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
    _backgroundedAt = null;
  }

  /// Bridge up / 外部补记 — 若阶段耗时尚未齐，会等 TTI（或超时）再上报。
  void noteColdStart({String? route}) {
    if (_coldStartNoted) return;
    unawaited(_emitColdStartWhenReady(routeHint: route));
  }

  Future<void> _emitColdStartWhenReady({String? routeHint}) async {
    if (_coldStartNoted) return;
    final clock = ColdStartClock.instance;
    await clock.firstFrameReady;
    await clock.waitInteractive(timeout: const Duration(seconds: 2));
    if (_coldStartNoted) return;
    _coldStartNoted = true;

    final metrics = clock.metrics();
    final phases = buildColdStartPhases(metrics);
    final route = routeHint ?? FastTrackMcpNetwork.currentRoute();
    final ttff = (metrics['ttffMs'] as num?)?.toDouble();
    final tti = (metrics['ttiMs'] as num?)?.toDouble();

    // 冷启落地路由写入栈，避免随后 Get.toNamed 的 from 竞态成目标页自身。
    if (route != null && route.isNotEmpty) {
      TransitionLedger.instance.seedShell(route);
    }

    _record(
      kind: 'cold_start',
      label: 'App 启动',
      route: route,
      at: DateTime.now(),
      extra: {
        if (ttff != null) 'ttff_ms': ttff,
        if (tti != null) 'tti_ms': tti,
        if (ttff != null) 'ttffMs': ttff,
        if (tti != null) 'ttiMs': tti,
        'startup': metrics,
        if (phases.isNotEmpty) 'startup_phases': phases,
        if (phases.isNotEmpty) 'startupPhases': phases,
      },
    );

    // 慢启动告警挂在同一生命周期段（控制台按 route/时间归并）
    const ttffWarnMs = 1500.0;
    if (ttff != null && ttff >= ttffWarnMs) {
      unawaited(
        FastTrackMcpDetectSink.track(
          'perf_slow_cold_start',
          properties: {
            'action': 'cold_start',
            'message':
                'TTFF ${ttff.toStringAsFixed(0)} ms ≥ 阈值 ${ttffWarnMs.toStringAsFixed(0)} ms',
            'severity': ttff >= 3000 ? 'critical' : 'warning',
            'startup': metrics,
            'ttff_ms': ttff,
            'threshold_ms': ttffWarnMs,
            if (route != null && route.isNotEmpty) 'route': route,
          },
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final route = FastTrackMcpNetwork.currentRoute();
    final now = DateTime.now();

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Mobile transitions commonly deliver hidden then paused for one exit.
      if (_backgroundedAt != null) return;
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
    Map<String, dynamic>? extra,
  }) {
    lastEvent = {
      'kind': kind,
      'label': label,
      'at': at.toIso8601String(),
      if (route != null && route.isNotEmpty) 'route': route,
      if (backgroundMs != null) 'backgroundMs': backgroundMs,
      if (extra != null) ...extra,
    };
    debugPrint(
      '[AppLifecycleTracker] $kind route=$route '
      'ttff=${extra?['ttff_ms'] ?? extra?['ttffMs']} '
      'tti=${extra?['tti_ms'] ?? extra?['ttiMs']}',
    );

    unawaited(
      FastTrackMcpDetectSink.track(
        'app_lifecycle',
        properties: {
          'kind': kind,
          'label': label,
          if (route != null && route.isNotEmpty) 'route': route,
          if (backgroundMs != null) 'background_ms': backgroundMs,
          if (extra != null) ...extra,
        },
        flush: kind == 'background',
      ),
    );
  }
}
