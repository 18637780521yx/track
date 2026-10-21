import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'hit_target.dart';
import 'network_capture.dart';
import 'perf_snapshot.dart';
import 'session_journal.dart';
import 'transition_leak_tracker.dart';
import 'transition_ledger.dart';

/// Records user taps into [SessionJournal] via global pointer route + hitTest.
class ManualGestureRecorder {
  ManualGestureRecorder._();
  static final ManualGestureRecorder instance = ManualGestureRecorder._();

  bool _started = false;
  bool _busy = false;
  DateTime? _lastAt;
  Offset? _downPos;
  DateTime? _downAt;
  int? _downPointer;
  String? _lastRoute;

  void ensureStarted() {
    if (_started || kReleaseMode) return;
    _started = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    debugPrint('[ManualGestureRecorder] started');
  }

  void stop() {
    if (!_started) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _started = false;
    _lastRoute = null;
  }

  /// Call when a new session begins so navigate diffs don't cross sessions.
  void resetRouteTracking() => _lastRoute = null;

  void _onPointer(PointerEvent event) {
    final journal = SessionJournal.instance;
    if (!journal.manualRecording) return;
    if (journal.suppressManual) return;

    if (event is PointerDownEvent) {
      _downPos = event.position;
      _downPointer = event.pointer;
      // Stamp press time — before PointerUp / onPressed starts HTTP.
      _downAt = DateTime.now();
      return;
    }

    if (event is PointerUpEvent) {
      if (_downPointer != null && event.pointer != _downPointer) return;
      final down = _downPos;
      final gestureAt = _downAt ?? DateTime.now();
      _downPos = null;
      _downPointer = null;
      _downAt = null;
      if (down == null) return;

      // Treat as scroll if moved too far.
      final moved = (event.position - down).distance;
      if (moved > 24) {
        unawaited(_recordScroll(down, event.position, gestureAt: gestureAt));
        return;
      }

      unawaited(
        _recordTap(
          event.position,
          viewId: event.viewId,
          gestureAt: gestureAt,
        ),
      );
    }
  }

  Future<void> _recordTap(
    Offset position, {
    required int viewId,
    required DateTime gestureAt,
  }) async {
    final journal = SessionJournal.instance;
    if (_busy) return;
    final now = DateTime.now();
    if (_lastAt != null && now.difference(_lastAt!).inMilliseconds < 280) {
      return;
    }
    if (!journal.isActive && !journal.ensureManualSession()) return;

    _busy = true;
    _lastAt = now;
    try {
      final before = PerfSnapshot.capture(sleuth: false);
      // Window start = finger down (not "now" after onPressed may have run).
      final t0 = gestureAt;
      // Route where the tap happened — NOT after login navigates away.
      final routeAtStart = PerfNetworkCapture.currentRoute();

      // Let the framework finish handling the real tap first.
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final target = HitTargetResolver.resolve(position, viewId: viewId);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await SchedulerBinding.instance.endOfFrame;

      final after = PerfSnapshot.capture();
      final diff = PerfDiff(
        before: before,
        after: after,
        durationMs: DateTime.now().difference(t0).inMilliseconds,
      );

      final gestureAtIso = gestureAt.toIso8601String();
      final label = 'manual_tap:${target.displayLabel}';
      final stepId = journal.nextStepId();
      // Settle first so post-op shot reflects the page after navigation.
      final settled = await _awaitNetworkAndRoute(t0, routeAtStart);
      final nets = _networkSince(t0);
      final routeAfter =
          settled.routeAfter ?? PerfNetworkCapture.currentRoute();
      final navAt = _navigateAt(
        detectedAt: settled.routeChangedAt,
        routeAfter: routeAfter,
        nets: nets,
      );
      final navResult = await _navigateIfChanged(
        routeAfter,
        navAt,
        stepId: stepId,
      );
      final nav = navResult?.event;
      final shot = await _captureScreenshot(stepId);
      final shotAt = DateTime.now().toIso8601String();
      final shotRoute =
          PerfNetworkCapture.currentRoute() ?? routeAfter ?? routeAtStart;
      final at = DateTime.now().toIso8601String();
      final step = StepResult(
        stepId: stepId,
        action: routeAtStart != null && routeAtStart.isNotEmpty
            ? 'route:$routeAtStart'
            : label,
        route: routeAtStart,
        ok: true,
        driver: 'manual_hit_test',
        actionResult: ActionResult(
          success: true,
          driver: 'manual',
          detail: target.toJson(),
        ),
        diff: diff.toData(),
        networkRequests: nets,
        screenshotPath: shot.path,
        screenshotDataUri: shot.dataUri,
        events: _timeline(
          gestureAt: gestureAtIso,
          shotAt: shotAt,
          actionRoute: routeAtStart,
          shotRoute: shotRoute,
          label: label,
          shot: shot,
          nets: nets,
          navigate: nav,
          detail: {
            'source': 'manual',
            'kind': 'tap',
            'target': target.toJson(),
          },
        ),
        alerts: navResult?.alerts ?? const [],
        at: at,
        extra: {
          'source': 'manual',
          'kind': 'tap',
          'cause': label,
          'actions': [label],
          'target': target.toJson(),
          if (nav != null) 'routeChanged': true,
          if (navResult?.leakProbe != null)
            'transitionLeak': navResult!.leakProbe!.toJson(),
        },
      );
      journal.addStep(step);
      debugPrint(
        '[ManualGestureRecorder] tap ${target.displayLabel} '
        '(${journal.steps.length} steps)',
      );
    } catch (e, st) {
      debugPrint('[ManualGestureRecorder] tap failed: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  Future<void> _recordScroll(
    Offset from,
    Offset to, {
    required DateTime gestureAt,
  }) async {
    final journal = SessionJournal.instance;
    if (_busy) return;
    if (!journal.isActive && !journal.ensureManualSession()) return;

    _busy = true;
    try {
      final before = PerfSnapshot.capture(sleuth: false);
      final t0 = gestureAt;
      final routeAtStart = PerfNetworkCapture.currentRoute();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final after = PerfSnapshot.capture();
      final diff = PerfDiff(
        before: before,
        after: after,
        durationMs: DateTime.now().difference(t0).inMilliseconds,
      );
      final dx = to.dx - from.dx;
      final dy = to.dy - from.dy;
      final direction = dy.abs() >= dx.abs()
          ? (dy < 0 ? 'up' : 'down')
          : (dx < 0 ? 'left' : 'right');
      final gestureAtIso = gestureAt.toIso8601String();
      final label = 'manual_scroll:$direction';
      final stepId = journal.nextStepId();
      final settled = await _awaitNetworkAndRoute(t0, routeAtStart);
      final nets = _networkSince(t0);
      final routeAfter =
          settled.routeAfter ?? PerfNetworkCapture.currentRoute();
      final navAt = _navigateAt(
        detectedAt: settled.routeChangedAt,
        routeAfter: routeAfter,
        nets: nets,
      );
      final navResult = await _navigateIfChanged(
        routeAfter,
        navAt,
        stepId: stepId,
      );
      final nav = navResult?.event;
      final shot = await _captureScreenshot(stepId);
      final shotAt = DateTime.now().toIso8601String();
      final shotRoute =
          PerfNetworkCapture.currentRoute() ?? routeAfter ?? routeAtStart;
      final at = DateTime.now().toIso8601String();
      final step = StepResult(
        stepId: stepId,
        action: routeAtStart != null && routeAtStart.isNotEmpty
            ? 'route:$routeAtStart'
            : label,
        route: routeAtStart,
        ok: true,
        driver: 'manual_hit_test',
        diff: diff.toData(),
        networkRequests: nets,
        screenshotPath: shot.path,
        screenshotDataUri: shot.dataUri,
        events: _timeline(
          gestureAt: gestureAtIso,
          shotAt: shotAt,
          actionRoute: routeAtStart,
          shotRoute: shotRoute,
          label: label,
          shot: shot,
          nets: nets,
          navigate: nav,
          detail: {
            'source': 'manual',
            'kind': 'scroll',
            'direction': direction,
            'from': {'x': from.dx, 'y': from.dy},
            'to': {'x': to.dx, 'y': to.dy},
          },
        ),
        alerts: navResult?.alerts ?? const [],
        at: at,
        extra: {
          'source': 'manual',
          'kind': 'scroll',
          'cause': label,
          'actions': [label],
          'direction': direction,
          if (nav != null) 'routeChanged': true,
          if (navResult?.leakProbe != null)
            'transitionLeak': navResult!.leakProbe!.toJson(),
        },
      );
      journal.addStep(step);
    } catch (e, st) {
      debugPrint('[ManualGestureRecorder] scroll failed: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  /// Emit navigate when route differs; on pop, probe WeakRef leaks (no forced GC).
  Future<_NavResult?> _navigateIfChanged(
    String? route,
    String at, {
    required String stepId,
  }) async {
    final prev = _lastRoute;
    final next = (route != null && route.isNotEmpty) ? route : null;
    _lastRoute = next ?? prev;
    if (prev == null || next == null || prev == next) return null;

    final kind = TransitionLedger.instance.resolveKind(from: prev, to: next);
    final detail = <String, dynamic>{
      'from': prev,
      'to': next,
      'transitionKind': kind,
    };

    TransitionLeakProbe? probe;
    var alerts = <AlertItem>[];
    if (isClosingTransitionKind(kind, fromRoute: prev, toRoute: next)) {
      probe = await TransitionLeakTracker.instance.probeAfterPop(
        poppedRoute: prev,
      );
      detail['leak'] = probe.toJson();
      alerts = TransitionLeakTracker.instance.alertsForProbe(
        probe: probe,
        stepId: stepId,
        action: 'navigate:$prev→$next',
      );
    }

    return _NavResult(
      event: StepEvent(
        type: 'navigate',
        at: at,
        label: '$prev → $next',
        detail: detail,
      ),
      alerts: alerts,
      leakProbe: probe,
    );
  }

  /// Events stamped with real times; report sorts chronologically by [at].
  ///
  /// - action: [gestureAt] on [actionRoute] (where the tap happened)
  /// - network: request [NetworkRequest.startedAt] / its own route
  /// - screenshot: [shotAt] on [shotRoute] (page visible when captured)
  List<StepEvent> _timeline({
    required String gestureAt,
    required String shotAt,
    required String? actionRoute,
    required String? shotRoute,
    required String label,
    required _Shot shot,
    required List<NetworkRequest> nets,
    required Map<String, dynamic> detail,
    StepEvent? navigate,
  }) {
    final events = <StepEvent>[
      StepEvent(
        type: 'action',
        at: gestureAt,
        label: label,
        ok: true,
        detail: {
          ...detail,
          if (actionRoute != null && actionRoute.isNotEmpty) 'route': actionRoute,
        },
      ),
      for (final r in nets)
        StepEvent(
          type: 'network',
          at: r.startedAt,
          label: '${r.method} ${_shortUrl(r.url)}',
          ok: r.statusCode > 0 && r.statusCode < 400,
          detail: r.toJson(),
        ),
      if (shot.dataUri != null || shot.path != null)
        StepEvent(
          type: 'screenshot',
          at: shotAt,
          label: '操作后截图',
          screenshotPath: shot.path,
          screenshotDataUri: shot.dataUri,
          detail: {
            if (shotRoute != null && shotRoute.isNotEmpty) 'route': shotRoute,
          },
        ),
      if (navigate != null) navigate,
    ];
    events.sort((a, b) {
      final ta = DateTime.tryParse(a.at);
      final tb = DateTime.tryParse(b.at);
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return ta.compareTo(tb);
    });
    return events;
  }

  /// Wait for network settle while watching for the first route change.
  ///
  /// Navigate must be stamped when the route flips — not after this wait —
  /// otherwise dest-page APIs (e.g. `/api/home/list`) sort before the
  /// transition segment.
  Future<_SettleResult> _awaitNetworkAndRoute(
    DateTime since,
    String? routeAtStart,
  ) async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 2000));
    var last = -1;
    var stableMs = 0;
    DateTime? routeChangedAt;
    String? routeAfter;
    while (DateTime.now().isBefore(deadline)) {
      final nowRoute = PerfNetworkCapture.currentRoute();
      if (routeChangedAt == null &&
          routeAtStart != null &&
          routeAtStart.isNotEmpty &&
          nowRoute != null &&
          nowRoute.isNotEmpty &&
          nowRoute != routeAtStart) {
        routeChangedAt = DateTime.now();
        routeAfter = nowRoute;
      }
      final n = _networkSince(since).length;
      if (n > 0 && n == last) {
        stableMs += 100;
        if (stableMs >= 250) {
          return _SettleResult(
            routeChangedAt: routeChangedAt,
            routeAfter: routeAfter ?? nowRoute,
          );
        }
      } else {
        stableMs = 0;
        last = n;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _SettleResult(
      routeChangedAt: routeChangedAt,
      routeAfter: routeAfter ?? PerfNetworkCapture.currentRoute(),
    );
  }

  /// Prefer first observed route flip; else just before earliest dest-route net.
  String _navigateAt({
    required DateTime? detectedAt,
    required String? routeAfter,
    required List<NetworkRequest> nets,
  }) {
    DateTime? earliestDest;
    if (routeAfter != null && routeAfter.isNotEmpty) {
      for (final r in nets) {
        if (r.route != routeAfter) continue;
        final t = DateTime.tryParse(r.startedAt);
        if (t == null) continue;
        if (earliestDest == null || t.isBefore(earliestDest)) {
          earliestDest = t;
        }
      }
    }
    // Keep navigate strictly before dest-page traffic (same-ms tie would
    // still put network first via type rank).
    DateTime? nav = detectedAt;
    if (earliestDest != null) {
      final beforeDest =
          earliestDest.subtract(const Duration(milliseconds: 1));
      if (nav == null || !nav.isBefore(earliestDest)) {
        nav = beforeDest;
      }
    }
    return (nav ?? DateTime.now()).toIso8601String();
  }

  /// HTTP from [PerfNetworkStore] for this gesture window.
  ///
  /// Small lookback covers onPressed starting the request slightly before [t0].
  List<NetworkRequest> _networkSince(DateTime since) {
    final from = since.subtract(const Duration(milliseconds: 500));
    final out = <NetworkRequest>[];
    for (final r in PerfNetworkStore.instance.records) {
      final at = DateTime.tryParse(r.startedAt);
      if (at != null && at.isBefore(from)) continue;
      out.add(r);
    }
    return out;
  }

  Future<_Shot> _captureScreenshot(String stepId) async {
    try {
      await SchedulerBinding.instance.endOfFrame;
      final image = await _captureScene();
      if (image == null) return const _Shot();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return const _Shot();
      final bytes = data.buffer.asUint8List();
      final b64 = base64Encode(bytes);
      final journal = SessionJournal.instance;
      final sid = journal.sessionId ?? 'manual';
      final dir = Directory(
        p.join(journal.reportsDir, 'screenshots', sid),
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      final path = p.join(dir.path, '$stepId.png');
      await File(path).writeAsBytes(bytes);
      return _Shot(path: path, dataUri: 'data:image/png;base64,$b64');
    } catch (e) {
      debugPrint('[ManualGestureRecorder] screenshot failed: $e');
      return const _Shot();
    }
  }

  Future<ui.Image?> _captureScene() async {
    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    final renderObject = binding.rootElement?.renderObject;
    if (renderObject == null) return null;

    RenderObject root = renderObject;
    while (root.parent != null) {
      root = root.parent!;
    }
    // ignore: invalid_use_of_protected_member
    final layer = root.layer;
    if (layer is OffsetLayer) {
      final view = binding.platformDispatcher.views.first;
      return layer.toImage(
        Offset.zero & view.physicalSize,
        pixelRatio: 1 / view.devicePixelRatio,
      );
    }
    if (renderObject is RenderRepaintBoundary) {
      return renderObject.toImage(pixelRatio: 1);
    }
    return null;
  }

  static String _shortUrl(String url) {
    try {
      final u = Uri.parse(url);
      return u.path.isEmpty ? url : u.path;
    } catch (_) {
      return url;
    }
  }
}

class _Shot {
  const _Shot({this.path, this.dataUri});
  final String? path;
  final String? dataUri;
}

class _NavResult {
  const _NavResult({
    required this.event,
    this.alerts = const [],
    this.leakProbe,
  });

  final StepEvent event;
  final List<AlertItem> alerts;
  final TransitionLeakProbe? leakProbe;
}

class _SettleResult {
  const _SettleResult({this.routeChangedAt, this.routeAfter});

  final DateTime? routeChangedAt;
  final String? routeAfter;
}
