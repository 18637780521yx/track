import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'detect_sink.dart';
import 'event_names.dart';

/// 卡顿 / 掉帧监测：监听 [SchedulerBinding.addTimingsCallback]。
///
/// - **slow**：build 或 raster 超过预算（默认读取屏幕刷新率，未知时按 60fps）
/// - **latency**：总延迟单独统计，不等同于处理阶段掉帧
/// - **frozen**：单帧总耗时超过 [frozenFrameThreshold]（默认 700ms，对齐常见 APM）
///
/// 默认按窗口聚合上报一条 `app_jank`，避免每帧打点打爆队列；
/// frozen 帧额外立即上报（带冷却）。
class FastTrackMcpJankMonitor {
  FastTrackMcpJankMonitor._();

  static const int _defaultFpsTarget = 60;
  static const Duration _defaultReportInterval = Duration(seconds: 10);
  static const Duration _defaultFrozenThreshold = Duration(milliseconds: 700);
  static const Duration _frozenReportCoolDown = Duration(seconds: 15);

  static bool _started = false;
  static int _fpsTarget = _defaultFpsTarget;
  static double _budgetMs = 1000 / _defaultFpsTarget;
  static Duration _reportInterval = _defaultReportInterval;
  static Duration _frozenThreshold = _defaultFrozenThreshold;
  static int _minSlowFramesToReport = 3;

  static Timer? _reportTimer;
  static Future<void> Function(Map<String, dynamic> properties)? _onJank;

  static int _windowFrames = 0;
  static int _windowSlow = 0;
  static int _windowFrozen = 0;
  static double _maxTotalMs = 0;
  static double _maxBuildMs = 0;
  static double _maxRasterMs = 0;
  static double _sumSlowMs = 0;
  static DateTime? _lastFrozenReportAt;
  static Future<void>? _draining;
  static Map<String, dynamic>? _pendingWindow;
  static Map<String, dynamic>? _pendingFrozen;
  static bool _autoFps = true;
  static int _windowBuildSlow = 0;
  static int _windowRasterSlow = 0;
  static int _windowHighLatency = 0;

  /// 测试注入。
  @visibleForTesting
  static Future<void> Function(String name, Map<String, dynamic> properties)?
      debugOnReport;

  static bool get isStarted => _started;

  /// 启动监测。需在 [WidgetsFlutterBinding.ensureInitialized] 之后。
  static void start({
    int? fpsTarget,
    Duration reportInterval = _defaultReportInterval,
    Duration frozenFrameThreshold = _defaultFrozenThreshold,
    int minSlowFramesToReport = 3,
    Future<void> Function(Map<String, dynamic> properties)? onJank,
  }) {
    if (_started) return;
    if (fpsTarget != null && fpsTarget <= 0) {
      debugPrint('[ftm] jank monitor skipped: fpsTarget must be > 0');
      return;
    }
    if (frozenFrameThreshold <= Duration.zero) return;

    _autoFps = fpsTarget == null;
    _fpsTarget = fpsTarget ?? _displayFps();
    _budgetMs = 1000.0 / _fpsTarget;
    _reportInterval = reportInterval;
    _frozenThreshold = frozenFrameThreshold;
    _minSlowFramesToReport =
        minSlowFramesToReport < 1 ? 1 : minSlowFramesToReport;
    _onJank = onJank;
    _resetWindow();

    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    _reportTimer?.cancel();
    if (reportInterval > Duration.zero) {
      _reportTimer = Timer.periodic(reportInterval, (_) {
        unawaited(_flushWindow(reason: 'interval'));
      });
    }

    _started = true;
    debugPrint(
      '[ftm] jank monitor started '
      '(fps=$_fpsTarget budget=${_budgetMs.toStringAsFixed(1)}ms '
      'frozen=${_frozenThreshold.inMilliseconds}ms)',
    );
  }

  static Future<void> stop() async {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    _reportTimer?.cancel();
    _reportTimer = null;
    await _flushWindow(reason: 'stop');
    await _draining;
    _started = false;
    _onJank = null;
  }

  @visibleForTesting
  static Future<void> debugReset() async {
    if (_started) {
      WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    }
    _reportTimer?.cancel();
    _reportTimer = null;
    _started = false;
    _onJank = null;
    debugOnReport = null;
    _lastFrozenReportAt = null;
    await _draining;
    _pendingWindow = null;
    _pendingFrozen = null;
    _resetWindow();
    _fpsTarget = _defaultFpsTarget;
    _budgetMs = 1000 / _defaultFpsTarget;
    _reportInterval = _defaultReportInterval;
    _frozenThreshold = _defaultFrozenThreshold;
    _minSlowFramesToReport = 3;
  }

  /// 测试用：直接喂 [FrameTiming]。
  @visibleForTesting
  static void debugHandleTimings(List<FrameTiming> timings) =>
      _onTimings(timings);

  /// 测试用：立刻按窗口规则尝试上报。
  @visibleForTesting
  static Future<void> debugFlushWindow() => _flushWindow(reason: 'test');

  static void _onTimings(List<FrameTiming> timings) {
    if (!_started) return;
    if (_autoFps) {
      final fps = _displayFps();
      if (fps != _fpsTarget) {
        unawaited(_flushWindow(reason: 'refresh_rate_changed'));
        _fpsTarget = fps;
        _budgetMs = 1000.0 / fps;
      }
    }
    for (final t in timings) {
      final totalMs = t.totalSpan.inMicroseconds / 1000.0;
      final buildMs = t.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;

      _windowFrames++;
      if (buildMs > _budgetMs) _windowBuildSlow++;
      if (rasterMs > _budgetMs) _windowRasterSlow++;
      if (totalMs > _budgetMs) _windowHighLatency++;
      if (totalMs > _maxTotalMs) _maxTotalMs = totalMs;
      if (buildMs > _maxBuildMs) _maxBuildMs = buildMs;
      if (rasterMs > _maxRasterMs) _maxRasterMs = rasterMs;

      if (buildMs > _budgetMs || rasterMs > _budgetMs) {
        _windowSlow++;
        _sumSlowMs += totalMs;
      }

      final frozenMs = _frozenThreshold.inMilliseconds.toDouble();
      if (totalMs >= frozenMs) {
        _windowFrozen++;
        unawaited(_reportFrozen(
          totalMs: totalMs,
          buildMs: buildMs,
          rasterMs: rasterMs,
        ));
        continue;
      }
    }
  }

  static Future<void> _reportFrozen({
    required double totalMs,
    required double buildMs,
    required double rasterMs,
  }) async {
    final now = DateTime.now();
    if (_lastFrozenReportAt != null &&
        now.difference(_lastFrozenReportAt!) < _frozenReportCoolDown) {
      return;
    }
    _lastFrozenReportAt = now;

    await _emit({
      'type': 'frozen_frame',
      'severity': 'frozen',
      'fps_target': _fpsTarget,
      'budget_ms': double.parse(_budgetMs.toStringAsFixed(2)),
      'frozen_threshold_ms': _frozenThreshold.inMilliseconds,
      'total_ms': double.parse(totalMs.toStringAsFixed(2)),
      'build_ms': double.parse(buildMs.toStringAsFixed(2)),
      'raster_ms': double.parse(rasterMs.toStringAsFixed(2)),
      'slow_frames': 1,
      'frozen_frames': 1,
      'total_frames': 1,
    });
  }

  static Future<void> _flushWindow({required String reason}) async {
    if (_windowFrames == 0) return;
    if (_windowSlow < _minSlowFramesToReport &&
        _windowFrozen == 0 &&
        _windowHighLatency < _minSlowFramesToReport) {
      _resetWindow();
      return;
    }

    final props = <String, dynamic>{
      'type': 'frame_window',
      'severity':
          _windowFrozen > 0 ? 'frozen' : (_windowSlow > 0 ? 'slow' : 'latency'),
      'reason': reason,
      'fps_target': _fpsTarget,
      'fps_targets': [_fpsTarget],
      'budget_ms': double.parse(_budgetMs.toStringAsFixed(2)),
      'frozen_threshold_ms': _frozenThreshold.inMilliseconds,
      'window_ms': _reportInterval.inMilliseconds,
      'total_frames': _windowFrames,
      'slow_frames': _windowSlow,
      'build_slow_frames': _windowBuildSlow,
      'raster_slow_frames': _windowRasterSlow,
      'high_latency_frames': _windowHighLatency,
      'frozen_frames': _windowFrozen,
      'max_total_ms': double.parse(_maxTotalMs.toStringAsFixed(2)),
      'max_build_ms': double.parse(_maxBuildMs.toStringAsFixed(2)),
      'max_raster_ms': double.parse(_maxRasterMs.toStringAsFixed(2)),
      'avg_slow_ms': _windowSlow == 0
          ? 0
          : double.parse((_sumSlowMs / _windowSlow).toStringAsFixed(2)),
      'jank_rate': _windowFrames == 0
          ? 0
          : double.parse((_windowSlow / _windowFrames).toStringAsFixed(4)),
    };
    _resetWindow();
    await _emit(props);
  }

  static int _displayFps() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final rate = views.isEmpty ? 0.0 : views.first.display.refreshRate;
    return rate.isFinite && rate > 0 ? rate.round() : _defaultFpsTarget;
  }

  // At most one pending aggregate per kind; merge windows while uploads are slow.
  static Future<void> _emit(Map<String, dynamic> properties) {
    if (properties['type'] == 'frame_window') {
      final previous = _pendingWindow;
      _pendingWindow =
          previous == null ? properties : _mergeWindows(previous, properties);
    } else {
      if (_pendingFrozen == null ||
          (properties['total_ms'] as num) >
              (_pendingFrozen!['total_ms'] as num)) {
        _pendingFrozen = properties;
      }
    }
    if (_draining != null) return _draining!;
    final completed = Completer<void>();
    _draining = completed.future;
    unawaited(() async {
      try {
        while (_pendingFrozen != null || _pendingWindow != null) {
          final next = _pendingFrozen ?? _pendingWindow!;
          if (_pendingFrozen != null) {
            _pendingFrozen = null;
          } else {
            _pendingWindow = null;
          }
          await _deliver(next);
        }
      } finally {
        _draining = null;
        completed.complete();
      }
    }());
    return completed.future;
  }

  static Map<String, dynamic> _mergeWindows(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final merged = <String, dynamic>{...b, 'reason': 'merged'};
    for (final key in [
      'total_frames',
      'slow_frames',
      'frozen_frames',
      'build_slow_frames',
      'raster_slow_frames',
      'high_latency_frames',
      'window_ms'
    ]) {
      merged[key] = (a[key] as num) + (b[key] as num);
    }
    for (final key in ['max_total_ms', 'max_build_ms', 'max_raster_ms']) {
      merged[key] = math.max(a[key] as num, b[key] as num);
    }
    final slow = merged['slow_frames'] as num;
    merged['avg_slow_ms'] = slow == 0
        ? 0
        : ((a['avg_slow_ms'] as num) * (a['slow_frames'] as num) +
                (b['avg_slow_ms'] as num) * (b['slow_frames'] as num)) /
            slow;
    merged['jank_rate'] = slow / (merged['total_frames'] as num);
    merged['fps_targets'] = <int>{
      ...a['fps_targets'] as List<int>,
      ...b['fps_targets'] as List<int>
    }.toList();
    merged['severity'] = (merged['frozen_frames'] as num) > 0
        ? 'frozen'
        : (slow > 0 ? 'slow' : 'latency');
    return merged;
  }

  static Future<void> _deliver(Map<String, dynamic> properties) async {
    try {
      final hook = debugOnReport;
      if (hook != null) {
        await hook(FastTrackMcpEventName.appJank, properties);
        return;
      }
      final frozen = properties['type'] == 'frozen_frame';
      await FastTrackMcpDetectSink.track(
        FastTrackMcpEventName.appJank,
        properties: properties,
        flush: frozen,
      );
      final onJank = _onJank;
      if (onJank != null) {
        await onJank(properties);
      }
    } catch (e) {
      debugPrint('[ftm] jank report failed: $e');
    }
  }

  static void _resetWindow() {
    _windowBuildSlow = 0;
    _windowRasterSlow = 0;
    _windowHighLatency = 0;
    _windowFrames = 0;
    _windowSlow = 0;
    _windowFrozen = 0;
    _maxTotalMs = 0;
    _maxBuildMs = 0;
    _maxRasterMs = 0;
    _sumSlowMs = 0;
  }
}
