import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../detect/detect_sink.dart';
import '../network/network_capture.dart';
import 'hit_target.dart';

/// 静默手势埋点：全局 pointer → tap / scroll → [FastTracker]。
///
/// 无 SessionJournal、无截图、无 UI 录制条。MCP 合成手势期间用
/// [beginMcpGuard] / [endMcpGuard] 抑制，避免与 `perf_mcp_step` 双计。
class ManualGestureRecorder {
  ManualGestureRecorder._();
  static final ManualGestureRecorder instance = ManualGestureRecorder._();

  bool _started = false;
  bool _busy = false;
  DateTime? _lastAt;
  Offset? _downPos;
  DateTime? _downAt;
  int? _downPointer;
  int _mcpGuardDepth = 0;

  bool get suppressManual => _mcpGuardDepth > 0;

  void beginMcpGuard() => _mcpGuardDepth++;

  void endMcpGuard() {
    if (_mcpGuardDepth > 0) _mcpGuardDepth--;
  }

  void ensureStarted() {
    if (_started || kReleaseMode) return;
    _started = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    debugPrint('[ManualGestureRecorder] silent track started');
  }

  void stop() {
    if (!_started) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _started = false;
  }

  void _onPointer(PointerEvent event) {
    if (suppressManual) return;

    if (event is PointerDownEvent) {
      _downPos = event.position;
      _downPointer = event.pointer;
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
    if (_busy || suppressManual) return;
    final now = DateTime.now();
    if (_lastAt != null && now.difference(_lastAt!).inMilliseconds < 280) {
      return;
    }

    _busy = true;
    _lastAt = now;
    try {
      final routeAtStart = FastTrackMcpNetwork.currentRoute();
      // 立刻命中：若先 delay，弹窗/转场会抢在 hit-test 前打开，落到图标 Listener。
      final target = HitTargetResolver.resolve(position, viewId: viewId);

      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final routeAfter = FastTrackMcpNetwork.currentRoute();

      await FastTrackMcpDetectSink.track(
        'ui_tap',
        properties: {
          'source': 'manual',
          'kind': 'tap',
          'label': target.displayLabel,
          'x': position.dx,
          'y': position.dy,
          if (routeAtStart != null) 'route': routeAtStart,
          if (routeAfter != null && routeAfter != routeAtStart)
            'route_after': routeAfter,
          'duration_ms': DateTime.now().difference(gestureAt).inMilliseconds,
          ...target.toJson(),
        },
        flush: true,
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
    if (_busy || suppressManual) return;
    _busy = true;
    try {
      final routeAtStart = FastTrackMcpNetwork.currentRoute();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final dx = to.dx - from.dx;
      final dy = to.dy - from.dy;
      final direction = dy.abs() >= dx.abs()
          ? (dy < 0 ? 'up' : 'down')
          : (dx < 0 ? 'left' : 'right');
      final routeAfter = FastTrackMcpNetwork.currentRoute();

      await FastTrackMcpDetectSink.track(
        'ui_scroll',
        properties: {
          'source': 'manual',
          'kind': 'scroll',
          'direction': direction,
          'from_x': from.dx,
          'from_y': from.dy,
          'to_x': to.dx,
          'to_y': to.dy,
          'distance': (to - from).distance,
          if (routeAtStart != null) 'route': routeAtStart,
          if (routeAfter != null && routeAfter != routeAtStart)
            'route_after': routeAfter,
          'duration_ms': DateTime.now().difference(gestureAt).inMilliseconds,
        },
        flush: true,
      );
    } catch (e, st) {
      debugPrint('[ManualGestureRecorder] scroll failed: $e\n$st');
    } finally {
      _busy = false;
    }
  }
}
