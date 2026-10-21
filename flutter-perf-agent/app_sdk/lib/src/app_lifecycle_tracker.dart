import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'network_capture.dart';
import 'session_journal.dart';

/// Records App 进入后台 / 进入前台 into [SessionJournal] while a session is active.
class AppLifecycleTracker with WidgetsBindingObserver {
  AppLifecycleTracker._();
  static final AppLifecycleTracker instance = AppLifecycleTracker._();

  bool _started = false;
  DateTime? _backgroundedAt;

  void ensureStarted() {
    if (kReleaseMode || _started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    if (!_started) return;
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
    _backgroundedAt = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final journal = SessionJournal.instance;
    if (!journal.isActive) return;

    final route = PerfNetworkCapture.currentRoute();
    final now = DateTime.now();

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt = now;
      _appendLifecycle(
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
      _appendLifecycle(
        kind: 'foreground',
        label: 'App 进入前台',
        route: route,
        at: now,
        backgroundMs: backgroundMs,
      );
    }
  }

  void _appendLifecycle({
    required String kind,
    required String label,
    required String? route,
    required DateTime at,
    int? backgroundMs,
  }) {
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
            type: 'lifecycle',
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
    debugPrint('[AppLifecycleTracker] $kind route=$route');
  }
}
