import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui';
import 'package:flutter/widgets.dart';

/// Dart/Flutter 侧冷启动计时（方案 A）：Dart 入口 → 首帧(TTFF) → 可交互(TTI)。
///
/// 细粒度 Engine Pre-Dart 需 VM 补充；此处至少给出业务可行动的分阶段。
class ColdStartClock {
  ColdStartClock._();
  static final ColdStartClock instance = ColdStartClock._();

  DateTime? _dartEntryAt;
  DateTime? _bindingReadyAt;
  DateTime? _runAppAt;
  DateTime? _firstFrameAt;
  DateTime? _interactiveAt;

  Completer<void> _interactiveWait = Completer<void>();
  Completer<void> _frameWait = Completer<void>();
  int? _entryUs, _rasterFinishUs, _interactiveUs;
  int? _frameworkDurationUs;
  bool _attachedLate = false;
  void Function(List<FrameTiming>)? _timingsCallback;
  final Map<String, double> _framePhases = {};
  Future<void> get firstFrameReady => _frameWait.future;

  void debugHandleTimings(List<FrameTiming> timings) =>
      _timingsCallback?.call(timings);

  void start() {
    markDartEntry();
    if (_timingsCallback != null || hasFirstFrame) return;
    final frameworkStart = Timeline.now;
    WidgetsFlutterBinding.ensureInitialized();
    _frameworkDurationUs = Timeline.now - frameworkStart;
    markBindingReady();
    if (WidgetsBinding.instance.firstFrameRasterized) {
      _attachedLate = true;
      if (!_frameWait.isCompleted) _frameWait.complete();
      return;
    }
    void callback(List<FrameTiming> timings) {
      if (timings.isEmpty) return;
      final first = timings.first;
      _rasterFinishUs = first.timestampInMicroseconds(FramePhase.rasterFinish);
      _framePhases.addAll({
        'firstFrameVsyncOverheadMs': first.vsyncOverhead.inMicroseconds / 1000,
        'firstFrameBuildMs': first.buildDuration.inMicroseconds / 1000,
        'firstFrameRasterMs': first.rasterDuration.inMicroseconds / 1000,
        'firstFrameTotalMs': first.totalSpan.inMicroseconds / 1000,
      });
      WidgetsBinding.instance.removeTimingsCallback(callback);
      _timingsCallback = null;
      markFirstFrame();
    }

    _timingsCallback = callback;
    WidgetsBinding.instance.addTimingsCallback(callback);
  }

  bool get hasFirstFrame => _firstFrameAt != null;
  bool get hasInteractive => _interactiveAt != null;

  /// 越早越好：`main` / CrashHandler 入口第一行。
  void markDartEntry([DateTime? at]) {
    _entryUs ??= Timeline.now;
    _dartEntryAt ??= at ?? DateTime.now();
  }

  /// `WidgetsFlutterBinding.ensureInitialized()` 之后。
  void markBindingReady([DateTime? at]) {
    markDartEntry(at);
    _bindingReadyAt ??= at ?? DateTime.now();
  }

  /// `runApp` 之前（业务 DI / 路由 / 存储等 boot 已完成）。
  void markRunApp([DateTime? at]) {
    markDartEntry(at);
    _runAppAt ??= at ?? DateTime.now();
  }

  /// 首帧回调。
  void markFirstFrame([DateTime? at]) {
    markDartEntry(at);
    _firstFrameAt ??= at ?? DateTime.now();
    if (!_frameWait.isCompleted) _frameWait.complete();
  }

  /// 首屏可交互（Tab 就绪 / 登录页就绪等）。未调用时 TTFF 后超时也会放行。
  void markInteractive([DateTime? at]) {
    markDartEntry(at);
    if (_interactiveAt != null) return;
    _interactiveAt = at ?? DateTime.now();
    _interactiveUs = Timeline.now;
    if (!_interactiveWait.isCompleted) {
      _interactiveWait.complete();
    }
  }

  Future<void> waitInteractive({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (_interactiveAt != null) return;
    try {
      await _interactiveWait.future.timeout(timeout);
    } on TimeoutException {
      // TTI ≈ TTFF（业务未显式 mark）
      // Leave TTI unknown until the business explicitly marks readiness.
    }
  }

  double? _msBetween(DateTime? a, DateTime? b) {
    if (a == null || b == null) return null;
    return b.difference(a).inMicroseconds / 1000.0;
  }

  /// 对齐 Sleuth startup JSON 字段，供 [buildColdStartPhases] 使用。
  Map<String, dynamic> metrics() {
    final dart = _dartEntryAt;
    final binding = _bindingReadyAt;
    final runApp = _runAppAt;
    final frame = _firstFrameAt;
    final interactive = _interactiveAt;

    final ttff = _rasterFinishUs != null && _entryUs != null
        ? (_rasterFinishUs! - _entryUs!) / 1000
        : _msBetween(dart, frame);
    final tti = _interactiveUs != null && _entryUs != null
        ? (_interactiveUs! - _entryUs!) / 1000
        : _msBetween(dart, interactive);
    final framework = _frameworkDurationUs != null
        ? _frameworkDurationUs! / 1000
        : _msBetween(dart, binding);
    // 业务启动：binding → runApp；若缺 binding 则 dart → runApp
    final firstFrameTotal = _framePhases['firstFrameTotalMs'] ??
        (runApp != null ? _msBetween(runApp, frame) : null);
    final bootstrap = runApp != null
        ? _msBetween(binding ?? dart, runApp)
        : (ttff != null && firstFrameTotal != null
            ? (ttff - (framework ?? 0) - firstFrameTotal)
                .clamp(0, ttff)
                .toDouble()
            : null);

    String? dominant;
    double? dominantPct;
    if (ttff != null && ttff > 0) {
      final candidates = <(String, double)>[
        if (framework != null) ('framework_init', framework),
        if (bootstrap != null) ('app_bootstrap', bootstrap),
        if (firstFrameTotal != null) ('first_frame', firstFrameTotal),
      ];
      if (candidates.isNotEmpty) {
        candidates.sort((a, b) => b.$2.compareTo(a.$2));
        dominant = candidates.first.$1;
        dominantPct = double.parse(
            ((candidates.first.$2 / ttff) * 100).toStringAsFixed(1));
      }
    }

    return {
      if (ttff != null) 'ttffMs': double.parse(ttff.toStringAsFixed(1)),
      if (tti != null) 'ttiMs': double.parse(tti.toStringAsFixed(1)),
      if (framework != null)
        'frameworkInitMs': double.parse(framework.toStringAsFixed(1)),
      if (bootstrap != null)
        'appBootstrapMs': double.parse(bootstrap.toStringAsFixed(1)),
      if (firstFrameTotal != null)
        'firstFrameTotalMs': double.parse(firstFrameTotal.toStringAsFixed(1)),
      ..._framePhases,
      'attachedLate': _attachedLate,
      'measurementScope': 'dart_sdk_entry_to_first_raster',
      'ttiSource': hasInteractive ? 'explicit' : 'unknown',
      'ttffSource':
          _rasterFinishUs != null ? 'frame_timing_monotonic' : 'manual',
      if (dominant != null) 'dominantPhase': dominant,
      if (dominantPct != null) 'dominantPhasePercent': dominantPct,
      'scheme': 'A',
      'source': 'cold_start_clock',
    };
  }

  /// 测试 / 热重启。
  void debugReset() {
    final callback = _timingsCallback;
    if (callback != null) {
      WidgetsBinding.instance.removeTimingsCallback(callback);
    }
    _timingsCallback = null;
    _entryUs = _rasterFinishUs = _interactiveUs = null;
    _frameworkDurationUs = null;
    _attachedLate = false;
    _framePhases.clear();
    _interactiveWait = Completer<void>();
    _frameWait = Completer<void>();
    _dartEntryAt = null;
    _bindingReadyAt = null;
    _runAppAt = null;
    _firstFrameAt = null;
    _interactiveAt = null;
  }
}
