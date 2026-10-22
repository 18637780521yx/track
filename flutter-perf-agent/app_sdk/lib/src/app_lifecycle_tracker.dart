import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'network_capture.dart';
import 'session_journal.dart';

/// Records App 启动 / 进入后台 / 进入前台.
///
/// Always keeps [lastEvent] for Bridge `/health` (MCP 可轮询，无需盲等).
/// Journal append only while a session is active.
class AppLifecycleTracker with WidgetsBindingObserver {
  AppLifecycleTracker._();
  static final AppLifecycleTracker instance = AppLifecycleTracker._();

  bool _started = false;
  DateTime? _backgroundedAt;
  bool _coldStartNoted = false;

  /// Latest lifecycle for Bridge health — independent of session.
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
    // First frame ≈ process usable; mark cold_start for health even before session.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      noteColdStart(route: PerfNetworkCapture.currentRoute());
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
      route: route ?? PerfNetworkCapture.currentRoute(),
      at: DateTime.now(),
      writeJournal: SessionJournal.instance.isActive,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final route = PerfNetworkCapture.currentRoute();
    final now = DateTime.now();
    final journalActive = SessionJournal.instance.isActive;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt = now;
      _record(
        kind: 'background',
        label: 'App 进入后台',
        route: route,
        at: now,
        writeJournal: journalActive,
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
        writeJournal: journalActive,
      );
    }
  }

  void _record({
    required String kind,
    required String label,
    required String? route,
    required DateTime at,
    int? backgroundMs,
    required bool writeJournal,
  }) {
    lastEvent = {
      'kind': kind,
      'label': label,
      'at': at.toIso8601String(),
      if (route != null && route.isNotEmpty) 'route': route,
      if (backgroundMs != null) 'backgroundMs': backgroundMs,
    };
    debugPrint('[AppLifecycleTracker] $kind route=$route journal=$writeJournal');

    if (!writeJournal) return;

    final journal = SessionJournal.instance;
    final stepId = journal.nextStepId();
    journal.addStep(
      StepResult(
        stepId: stepId,
        action: 'lifecycle:$kind',
        route: route,
        ok: true,
        driver: 'app_sdk',
        at: at.toIso8601String(),
        events: [
          StepEvent(
            type: kind == 'cold_start' ? 'cold_start' : 'lifecycle',
            at: at.toIso8601String(),
            label: label,
            detail: {
              'kind': kind,
              if (route != null) 'route': route,
              if (backgroundMs != null) 'backgroundMs': backgroundMs,
            },
          ),
        ],
        extra: {'source': 'lifecycle', 'kind': kind},
      ),
    );
  }
}
