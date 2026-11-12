import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'detect_sink.dart';
import 'event_names.dart';
import '../network/network_capture.dart';

/// 卡顿 / 掉帧监测：监听 [SchedulerBinding.addTimingsCallback]。
///
/// - **slow**：启动延迟 + build 或 raster 超预算；按样本数和比例判定模式
/// - **latency**：总延迟单独统计，不等同于处理阶段掉帧
/// - **frozen**：长延迟统计；独立阈值告警仅在显式启用时生效
///
/// 默认按窗口聚合上报一条 `app_jank`，避免每帧打点打爆队列；
/// 默认按刷新率预算与窗口模式告警。
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
  static bool _enableFrozenFrameAlerts = false;
  static int _minSlowFramesToReport = 3;
  static int _minSampleFrames = 5;
  static double _jankRateThreshold = .15;
  static Duration _warmup = const Duration(seconds: 3);
  static int? _firstVsyncUs;
  static int _windowSevere = 0, _windowLateStart = 0;
  static double _maxStartDelayMs = 0;
  static int? _windowFirstUs, _windowLastUs;
  static String? _windowRoute, _initialRoute;
  static bool _windowStartup = false;
  static bool _windowHasFrozenReport = false;
  static int _windowEpoch = 0;
  static int _epochSequence = 0;
  static final List<({int at, String? route, int epoch})> _routeEpochs = [];

  /// Transition timestamps share FrameTiming's monotonic microsecond domain.
  static int? markRoute(String? route, {int? atUs, bool force = false}) {
    if (!_started) return null;
    if (!force && _routeEpochs.isNotEmpty && _routeEpochs.last.route == route) {
      return _routeEpochs.last.epoch;
    }
    _routeEpochs
        .add((at: atUs ?? Timeline.now, route: route, epoch: ++_epochSequence));
    if (_routeEpochs.length > 64) _routeEpochs.removeAt(0);
    return _epochSequence;
  }

  static Timer? _reportTimer;
  static Future<void> Function(Map<String, dynamic> properties)? _onJank;

  static final List<({FrameTiming timing, bool frozenReported})> _recentFrames =
      [];
  static int _revision = 0, _reportedRevision = -1;
  static int? _lastRollingReportUs;
  static int _windowFrames = 0;
  static int _windowSlow = 0;
  static int _windowFrozen = 0;
  static double _maxTotalMs = 0;
  static double _maxBuildMs = 0;
  static double _maxRasterMs = 0;
  static double _sumSlowMs = 0;
  static DateTime? _lastFrozenReportAt;
  static Future<void>? _draining;
  static final List<Map<String, dynamic>> _pendingWindows = [];
  static final List<Map<String, dynamic>> _pendingFrozen = [];
  static int? _lastFrozenEpoch;
  static int? _lastFrozenFrameUs;
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
    bool enableFrozenFrameAlerts = false,
    int minSlowFramesToReport = 3,
    int minSampleFrames = 5,
    double jankRateThreshold = .15,
    Duration warmup = const Duration(seconds: 3),
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
    _enableFrozenFrameAlerts = enableFrozenFrameAlerts;
    _minSlowFramesToReport =
        minSlowFramesToReport < 1 ? 1 : minSlowFramesToReport;
    _minSampleFrames = math.max(1, minSampleFrames);
    _jankRateThreshold = jankRateThreshold.clamp(0, 1);
    _warmup = warmup < Duration.zero ? Duration.zero : warmup;
    _firstVsyncUs = null;
    _lastFrozenReportAt = null;
    _lastFrozenEpoch = null;
    _routeEpochs.clear();
    _epochSequence = 0;
    _windowRoute = _initialRoute = FastTrackMcpNetwork.currentRoute();
    _windowEpoch = 0;
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
    _lastFrozenEpoch = null;
    await _draining;
    _pendingWindows.clear();
    _pendingFrozen.clear();
    _resetWindow();
    _fpsTarget = _defaultFpsTarget;
    _budgetMs = 1000 / _defaultFpsTarget;
    _reportInterval = _defaultReportInterval;
    _frozenThreshold = _defaultFrozenThreshold;
    _minSlowFramesToReport = 3;
    _minSampleFrames = 5;
    _jankRateThreshold = .15;
    _warmup = const Duration(seconds: 3);
    _firstVsyncUs = null;
    _routeEpochs.clear();
    _windowRoute = null;
    _windowEpoch = _epochSequence = 0;
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
        _resetWindow();
        _fpsTarget = fps;
        _budgetMs = 1000.0 / fps;
      }
    }
    for (final t in timings) {
      final vsyncUs = t.timestampInMicroseconds(FramePhase.vsyncStart);
      _firstVsyncUs ??= vsyncUs;
      if (_routeEpochs.length == 64 && vsyncUs < _routeEpochs.first.at) {
        continue;
      }
      final epoch = _routeEpochs.where((e) => e.at <= vsyncUs).lastOrNull;
      final route = epoch != null ? epoch.route : _initialRoute;
      final epochId = epoch?.epoch ?? 0;
      if (epochId != _windowEpoch) {
        unawaited(_flushWindow(reason: 'route_changed'));
        _resetWindow();
        _windowRoute = route;
        _windowEpoch = epochId;
      }
      final totalMs = t.totalSpan.inMicroseconds / 1000.0;
      final buildMs = t.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;

      final delayMs = t.vsyncOverhead.inMicroseconds / 1000.0;
      final startup = vsyncUs - _firstVsyncUs! < _warmup.inMicroseconds;
      // Keep catastrophic frames during startup; normal startup work does not
      // enter steady-state jank statistics.
      if (startup &&
          (!_enableFrozenFrameAlerts ||
              totalMs < _frozenThreshold.inMilliseconds)) {
        continue;
      }
      if (_windowFrames > 0 && _windowStartup != startup) {
        unawaited(_flushWindow(reason: 'frame_time_boundary'));
        _resetWindow();
      }
      _windowStartup = startup;
      _windowFirstUs ??= vsyncUs;
      _windowLastUs = vsyncUs;
      _windowFrames++;
      if (delayMs > _maxStartDelayMs) _maxStartDelayMs = delayMs;
      if (delayMs + buildMs > _budgetMs && buildMs <= _budgetMs) {
        _windowLateStart++;
      }
      if (delayMs + buildMs > _budgetMs * 2 || rasterMs > _budgetMs * 2) {
        _windowSevere++;
      }
      if (buildMs > _budgetMs) _windowBuildSlow++;
      if (rasterMs > _budgetMs) _windowRasterSlow++;
      if (totalMs > _budgetMs) _windowHighLatency++;
      if (totalMs > _maxTotalMs) _maxTotalMs = totalMs;
      if (buildMs > _maxBuildMs) _maxBuildMs = buildMs;
      if (rasterMs > _maxRasterMs) _maxRasterMs = rasterMs;

      if (delayMs + buildMs > _budgetMs || rasterMs > _budgetMs) {
        _windowSlow++;
        _sumSlowMs += totalMs;
      }

      final frozenMs = _frozenThreshold.inMilliseconds.toDouble();
      if (totalMs >= frozenMs) {
        _windowFrozen++;
        if (_enableFrozenFrameAlerts) {
          unawaited(_reportFrozen(
            totalMs: totalMs,
            buildMs: buildMs,
            rasterMs: rasterMs,
            startDelayMs: delayMs,
            lifecycle: startup ? 'startup' : 'steady',
          ));
        }
      }
      _recentFrames
          .add((timing: t, frozenReported: _lastFrozenFrameUs == vsyncUs));
      _revision++;
      while (_recentFrames.length > 240 ||
          (_recentFrames.isNotEmpty &&
              vsyncUs -
                      _recentFrames.first.timing
                          .timestampInMicroseconds(FramePhase.vsyncStart) >
                  10000000)) {
        _recentFrames.removeAt(0);
      }
      _rebuildWindow();
    }
    if (_reportInterval > Duration.zero &&
        _windowLastUs != null &&
        (_lastRollingReportUs == null ||
            _windowLastUs! - _lastRollingReportUs! >=
                _reportInterval.inMicroseconds)) {
      unawaited(_flushWindow(reason: 'rolling'));
    }
  }

  static void _rebuildWindow() {
    _resetStatistics();
    for (final frame in _recentFrames) {
      final t = frame.timing;
      final at = t.timestampInMicroseconds(FramePhase.vsyncStart);
      final build = t.buildDuration.inMicroseconds / 1000.0;
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      final delay = t.vsyncOverhead.inMicroseconds / 1000.0;
      final total = t.totalSpan.inMicroseconds / 1000.0;
      _windowFirstUs ??= at;
      _windowLastUs = at;
      _windowFrames++;
      if (build > _budgetMs) _windowBuildSlow++;
      if (raster > _budgetMs) _windowRasterSlow++;
      if (delay + build > _budgetMs && build <= _budgetMs) _windowLateStart++;
      if (delay + build > _budgetMs * 2 || raster > _budgetMs * 2) {
        _windowSevere++;
      }
      if (delay + build > _budgetMs || raster > _budgetMs) {
        _windowSlow++;
        _sumSlowMs += total;
      }
      if (total > _budgetMs) _windowHighLatency++;
      if (total >= _frozenThreshold.inMilliseconds) _windowFrozen++;
      _windowHasFrozenReport |= frame.frozenReported;
      _maxTotalMs = math.max(_maxTotalMs, total);
      _maxBuildMs = math.max(_maxBuildMs, build);
      _maxRasterMs = math.max(_maxRasterMs, raster);
      _maxStartDelayMs = math.max(_maxStartDelayMs, delay);
    }
    _windowHasFrozenReport = _windowFrozen > 0 &&
        _recentFrames
            .where((f) =>
                f.timing.totalSpan.inMilliseconds >=
                _frozenThreshold.inMilliseconds)
            .every((f) => f.frozenReported);
  }

  static Future<void> _reportFrozen({
    required double totalMs,
    required double buildMs,
    required double rasterMs,
    required double startDelayMs,
    required String lifecycle,
  }) async {
    final now = DateTime.now();
    if (_lastFrozenEpoch == _windowEpoch &&
        _lastFrozenReportAt != null &&
        now.difference(_lastFrozenReportAt!) < _frozenReportCoolDown) {
      return;
    }
    _lastFrozenReportAt = now;
    _lastFrozenEpoch = _windowEpoch;
    _windowHasFrozenReport = true;
    _lastFrozenFrameUs = _windowLastUs;

    await _emit({
      'type': 'frozen_frame',
      'route': _windowRoute,
      'route_epoch': _windowEpoch,
      'lifecycle_phase': lifecycle,
      'start_delay_ms': startDelayMs,
      'frame_at_us': _windowLastUs,
      'detector_version': 2,
      'severity': 'frozen',
      'fps_target': _fpsTarget,
      'budget_ms': double.parse(_budgetMs.toStringAsFixed(2)),
      'frozen_threshold_ms': _frozenThreshold.inMilliseconds,
      'total_ms': double.parse(totalMs.toStringAsFixed(2)),
      'build_ms': double.parse(buildMs.toStringAsFixed(2)),
      'raster_ms': double.parse(rasterMs.toStringAsFixed(2)),
      'slow_frames':
          startDelayMs + buildMs > _budgetMs || rasterMs > _budgetMs ? 1 : 0,
      'frozen_frames': 1,
      'total_frames': 1,
    });
  }

  static Future<void> _flushWindow({required String reason}) async {
    if (_windowFrames == 0 || _revision == _reportedRevision) return;
    final rate = _windowSlow / _windowFrames;
    final enough = _windowFrames >= _minSampleFrames;
    final sustained = enough && _windowSevere >= 3;
    final jank = enough &&
        _windowSlow >= _minSlowFramesToReport &&
        rate > _jankRateThreshold;
    final latency = enough &&
        _windowSlow == 0 &&
        _windowHighLatency >= _minSlowFramesToReport &&
        _windowHighLatency / _windowFrames > _jankRateThreshold;
    if (!sustained &&
        !jank &&
        !latency &&
        (!_enableFrozenFrameAlerts || _windowFrozen == 0)) {
      return;
    }

    final props = <String, dynamic>{
      'type': 'frame_window',
      'detector_version': 3,
      'window_mode': 'rolling',
      'window_capacity': 240,
      'route': _windowRoute,
      'route_epoch': _windowEpoch,
      'lifecycle_phase': _windowStartup ? 'startup' : 'steady',
      'jank_detected': jank,
      'sustained_jank': sustained,
      'severe_frames': _windowSevere,
      'late_start_frames': _windowLateStart,
      'max_start_delay_ms': _maxStartDelayMs,
      'min_sample_frames': _minSampleFrames,
      'jank_rate_threshold': _jankRateThreshold,
      'first_frame_at_us': _windowFirstUs,
      'last_frame_at_us': _windowLastUs,
      'observed_span_ms': ((_windowLastUs ?? 0) - (_windowFirstUs ?? 0)) / 1000,
      'frozen_reported_separately': _windowHasFrozenReport,
      'frozen_alerts_enabled': _enableFrozenFrameAlerts,
      'severity': _enableFrozenFrameAlerts && _windowFrozen > 0
          ? 'frozen'
          : (sustained ? 'severe' : (_windowSlow > 0 ? 'slow' : 'latency')),
      'reason': reason,
      'fps_target': _fpsTarget,
      'fps_targets': [_fpsTarget],
      'budget_ms': double.parse(_budgetMs.toStringAsFixed(2)),
      'frozen_threshold_ms': _frozenThreshold.inMilliseconds,
      'window_ms': 10000,
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
    _reportedRevision = _revision;
    _lastRollingReportUs = _windowLastUs;
    await _emit(props);
  }

  static int _displayFps() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final rate = views.isEmpty ? 0.0 : views.first.display.refreshRate;
    return rate.isFinite && rate > 0 ? rate.round() : _defaultFpsTarget;
  }

  // Bounded pending queues; only merge matching route epoch, phase and budget.
  static Future<void> _emit(Map<String, dynamic> properties) {
    if (properties['type'] == 'frame_window') {
      final index = _pendingWindows.indexWhere((p) =>
          p['route_epoch'] == properties['route_epoch'] &&
          p['route'] == properties['route'] &&
          p['lifecycle_phase'] == properties['lifecycle_phase'] &&
          p['fps_target'] == properties['fps_target']);
      if (index >= 0) {
        _pendingWindows[index] = properties;
      } else {
        if (_pendingWindows.length >= 32) {
          final discarded = _pendingWindows.removeAt(0);
          properties['dropped_report_windows'] =
              1 + ((discarded['dropped_report_windows'] as int?) ?? 0);
        }
        _pendingWindows.add(properties);
      }
    } else {
      final index = _pendingFrozen
          .indexWhere((p) => p['route_epoch'] == properties['route_epoch']);
      if (index >= 0) {
        if ((properties['total_ms'] as num) >
            (_pendingFrozen[index]['total_ms'] as num)) {
          _pendingFrozen[index] = properties;
        }
      } else {
        if (_pendingFrozen.length >= 32) {
          final dropped = _pendingFrozen.removeAt(0);
          properties['dropped_frozen_reports'] =
              1 + ((dropped['dropped_frozen_reports'] as int?) ?? 0);
        }
        _pendingFrozen.add(properties);
      }
    }

    if (_draining != null) return _draining!;
    final completed = Completer<void>();
    _draining = completed.future;
    unawaited(() async {
      try {
        while (_pendingFrozen.isNotEmpty || _pendingWindows.isNotEmpty) {
          final next = _pendingFrozen.isNotEmpty
              ? _pendingFrozen.removeAt(0)
              : _pendingWindows.removeAt(0);
          await _deliver(next);
        }
      } finally {
        _draining = null;
        completed.complete();
      }
    }());
    return completed.future;
  }

  static Future<void> _deliver(Map<String, dynamic> properties) async {
    try {
      final hook = debugOnReport;
      if (hook != null) {
        await hook(FastTrackMcpEventName.appJank, properties);
        return;
      }
      await FastTrackMcpDetectSink.track(
        FastTrackMcpEventName.appJank,
        properties: properties,
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
    _recentFrames.clear();
    _revision = 0;
    _reportedRevision = -1;
    _lastRollingReportUs = null;
    _resetStatistics();
  }

  static void _resetStatistics() {
    _windowHasFrozenReport = false;
    _windowSevere = _windowLateStart = 0;
    _maxStartDelayMs = 0;
    _windowFirstUs = _windowLastUs = null;
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
