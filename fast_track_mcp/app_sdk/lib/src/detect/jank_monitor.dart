import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'detect_sink.dart';
import 'event_names.dart';

/// 卡顿 / 掉帧监测：监听 [SchedulerBinding.addTimingsCallback]。
///
/// - **slow**：单帧总耗时超过预算（默认按 60fps → ~16.7ms）
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
  static bool _reporting = false;

  /// 测试注入。
  @visibleForTesting
  static Future<void> Function(String name, Map<String, dynamic> properties)?
      debugOnReport;

  static bool get isStarted => _started;

  /// 启动监测。需在 [WidgetsFlutterBinding.ensureInitialized] 之后。
  static void start({
    int fpsTarget = _defaultFpsTarget,
    Duration reportInterval = _defaultReportInterval,
    Duration frozenFrameThreshold = _defaultFrozenThreshold,
    int minSlowFramesToReport = 3,
    Future<void> Function(Map<String, dynamic> properties)? onJank,
  }) {
    if (_started) return;
    if (fpsTarget <= 0) {
      debugPrint('[ftm] jank monitor skipped: fpsTarget must be > 0');
      return;
    }

    _fpsTarget = fpsTarget;
    _budgetMs = 1000.0 / fpsTarget;
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
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    _reportTimer?.cancel();
    _reportTimer = null;
    await _flushWindow(reason: 'stop');
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
    _reporting = false;
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
    for (final t in timings) {
      final totalMs = t.totalSpan.inMicroseconds / 1000.0;
      final buildMs = t.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;

      _windowFrames++;
      if (totalMs > _maxTotalMs) _maxTotalMs = totalMs;
      if (buildMs > _maxBuildMs) _maxBuildMs = buildMs;
      if (rasterMs > _maxRasterMs) _maxRasterMs = rasterMs;

      final frozenMs = _frozenThreshold.inMilliseconds.toDouble();
      if (totalMs >= frozenMs) {
        _windowFrozen++;
        _windowSlow++;
        _sumSlowMs += totalMs;
        unawaited(_reportFrozen(
          totalMs: totalMs,
          buildMs: buildMs,
          rasterMs: rasterMs,
        ));
        continue;
      }

      if (totalMs > _budgetMs) {
        _windowSlow++;
        _sumSlowMs += totalMs;
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
    if (_windowSlow < _minSlowFramesToReport && _windowFrozen == 0) {
      _resetWindow();
      return;
    }

    final props = <String, dynamic>{
      'type': 'frame_window',
      'severity': _windowFrozen > 0 ? 'frozen' : 'slow',
      'reason': reason,
      'fps_target': _fpsTarget,
      'budget_ms': double.parse(_budgetMs.toStringAsFixed(2)),
      'frozen_threshold_ms': _frozenThreshold.inMilliseconds,
      'window_ms': _reportInterval.inMilliseconds,
      'total_frames': _windowFrames,
      'slow_frames': _windowSlow,
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

  static Future<void> _emit(Map<String, dynamic> properties) async {
    if (_reporting) return;
    _reporting = true;
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
    } finally {
      _reporting = false;
    }
  }

  static void _resetWindow() {
    _windowFrames = 0;
    _windowSlow = 0;
    _windowFrozen = 0;
    _maxTotalMs = 0;
    _maxBuildMs = 0;
    _maxRasterMs = 0;
    _sumSlowMs = 0;
  }
}
