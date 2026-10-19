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

/// Records user taps into [SessionJournal] via global pointer route + hitTest.
class ManualGestureRecorder {
  ManualGestureRecorder._();
  static final ManualGestureRecorder instance = ManualGestureRecorder._();

  bool _started = false;
  bool _busy = false;
  DateTime? _lastAt;
  Offset? _downPos;
  int? _downPointer;

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
  }

  void _onPointer(PointerEvent event) {
    final journal = SessionJournal.instance;
    if (!journal.manualRecording) return;
    if (journal.suppressManual) return;

    if (event is PointerDownEvent) {
      _downPos = event.position;
      _downPointer = event.pointer;
      return;
    }

    if (event is PointerUpEvent) {
      if (_downPointer != null && event.pointer != _downPointer) return;
      final down = _downPos;
      _downPos = null;
      _downPointer = null;
      if (down == null) return;

      // Treat as scroll if moved too far.
      final moved = (event.position - down).distance;
      if (moved > 24) {
        unawaited(_recordScroll(down, event.position));
        return;
      }

      unawaited(_recordTap(event.position, viewId: event.viewId));
    }
  }

  Future<void> _recordTap(Offset position, {required int viewId}) async {
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
      final t0 = DateTime.now();

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

      final route = PerfNetworkCapture.currentRoute();
      final at = DateTime.now().toIso8601String();
      final label = 'manual_tap:${target.displayLabel}';
      final stepId = journal.nextStepId();
      final shot = await _captureScreenshot(stepId);
      final nets = _networkSince(t0);
      final step = StepResult(
        stepId: stepId,
        action: route != null && route.isNotEmpty ? 'route:$route' : label,
        route: route,
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
          at: at,
          label: label,
          shot: shot,
          nets: nets,
          detail: {
            'source': 'manual',
            'kind': 'tap',
            'target': target.toJson(),
          },
        ),
        at: at,
        extra: {
          'source': 'manual',
          'kind': 'tap',
          'cause': label,
          'actions': [label],
          'target': target.toJson(),
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

  Future<void> _recordScroll(Offset from, Offset to) async {
    final journal = SessionJournal.instance;
    if (_busy) return;
    if (!journal.isActive && !journal.ensureManualSession()) return;

    _busy = true;
    try {
      final before = PerfSnapshot.capture(sleuth: false);
      final t0 = DateTime.now();
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
      final route = PerfNetworkCapture.currentRoute();
      final at = DateTime.now().toIso8601String();
      final label = 'manual_scroll:$direction';
      final stepId = journal.nextStepId();
      final shot = await _captureScreenshot(stepId);
      final nets = _networkSince(t0);
      final step = StepResult(
        stepId: stepId,
        action: route != null && route.isNotEmpty ? 'route:$route' : label,
        route: route,
        ok: true,
        driver: 'manual_hit_test',
        diff: diff.toData(),
        networkRequests: nets,
        screenshotPath: shot.path,
        screenshotDataUri: shot.dataUri,
        events: _timeline(
          at: at,
          label: label,
          shot: shot,
          nets: nets,
          detail: {
            'source': 'manual',
            'kind': 'scroll',
            'direction': direction,
            'from': {'x': from.dx, 'y': from.dy},
            'to': {'x': to.dx, 'y': to.dy},
          },
        ),
        at: at,
        extra: {
          'source': 'manual',
          'kind': 'scroll',
          'cause': label,
          'actions': [label],
          'direction': direction,
        },
      );
      journal.addStep(step);
    } catch (e, st) {
      debugPrint('[ManualGestureRecorder] scroll failed: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  /// Timeline order matches MCP HTML: screenshot → action → network.
  List<StepEvent> _timeline({
    required String at,
    required String label,
    required _Shot shot,
    required List<NetworkRequest> nets,
    required Map<String, dynamic> detail,
  }) {
    return [
      if (shot.dataUri != null || shot.path != null)
        StepEvent(
          type: 'screenshot',
          at: at,
          label: '操作后截图',
          screenshotPath: shot.path,
          screenshotDataUri: shot.dataUri,
        ),
      StepEvent(
        type: 'action',
        at: at,
        label: label,
        ok: true,
        detail: detail,
      ),
      for (final r in nets)
        StepEvent(
          type: 'network',
          at: r.startedAt,
          label: '${r.method} ${_shortUrl(r.url)}',
          ok: r.statusCode > 0 && r.statusCode < 400,
          detail: r.toJson(),
        ),
    ];
  }

  List<NetworkRequest> _networkSince(DateTime since) {
    final out = <NetworkRequest>[];
    for (final r in PerfNetworkStore.instance.records) {
      final at = DateTime.tryParse(r.startedAt);
      if (at != null && at.isBefore(since)) continue;
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
