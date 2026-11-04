import 'dart:async';

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

  final Completer<void> _interactiveWait = Completer<void>();

  bool get hasFirstFrame => _firstFrameAt != null;
  bool get hasInteractive => _interactiveAt != null;

  /// 越早越好：`main` / CrashHandler 入口第一行。
  void markDartEntry([DateTime? at]) {
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
  }

  /// 首屏可交互（Tab 就绪 / 登录页就绪等）。未调用时 TTFF 后超时也会放行。
  void markInteractive([DateTime? at]) {
    markDartEntry(at);
    if (_interactiveAt != null) return;
    _interactiveAt = at ?? DateTime.now();
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
      markInteractive(_firstFrameAt ?? DateTime.now());
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

    final ttff = _msBetween(dart, frame);
    final tti = _msBetween(dart, interactive);
    final framework = _msBetween(dart, binding);
    // 业务启动：binding → runApp；若缺 binding 则 dart → runApp
    final bootstrap = binding != null
        ? _msBetween(binding, runApp ?? frame)
        : _msBetween(dart, runApp ?? frame);
    final firstFrameTotal = runApp != null
        ? _msBetween(runApp, frame)
        : (binding != null ? _msBetween(binding, frame) : null);

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
        dominantPct =
            double.parse(((candidates.first.$2 / ttff) * 100).toStringAsFixed(1));
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
      // 无 Timeline 采样时，把首帧整段记在 build，便于阶段表展示
      if (firstFrameTotal != null)
        'firstFrameBuildMs': double.parse(firstFrameTotal.toStringAsFixed(1)),
      if (dominant != null) 'dominantPhase': dominant,
      if (dominantPct != null) 'dominantPhasePercent': dominantPct,
      'scheme': 'A',
      'source': 'cold_start_clock',
    };
  }

  /// 测试 / 热重启。
  void debugReset() {
    _dartEntryAt = null;
    _bindingReadyAt = null;
    _runAppAt = null;
    _firstFrameAt = null;
    _interactiveAt = null;
  }
}
