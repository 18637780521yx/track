import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../network/network_capture.dart';
import 'detect_sink.dart';
import 'event_names.dart';
import 'memory_evidence.dart';
import 'vm_memory_monitor.dart';

/// 内存泄漏 / 内存压力启发式监测（生产可用、轻量）。
///
/// **不是**对象级 WeakRef 根因分析（那是 perf-agent / DevTools 的活）。
/// 这里定期采样进程 RSS（[ProcessInfo.currentRss]），识别：
/// - **growth**：预热后滑动窗口回归 + 持续增长（仅趋势证据）
/// - **pressure**：最近 5 次有 4 次超过可配置预算
/// Debug/Profile 可通过 VM 采集堆与 GC；Release 只走轻量 RSS。
///
/// 上报事件名 [FastTrackMcpEventName.appMemoryLeak]，带冷却，避免刷屏。
class FastTrackMcpMemoryMonitor {
  FastTrackMcpMemoryMonitor._();

  static const Duration _defaultSampleInterval = Duration(seconds: 30);
  static const Duration _defaultCoolDown = Duration(minutes: 5);
  static const int _defaultGrowthStreak = 5;
  static const int _defaultMinGrowthBytes = 2 * 1024 * 1024; // 2 MiB
  static const int _defaultPressureBytes = 512 * 1024 * 1024; // 512 MiB

  static bool _started = false;
  static Timer? _timer;
  static Duration _sampleInterval = _defaultSampleInterval;
  static Duration _coolDown = _defaultCoolDown;
  static int _growthStreak = _defaultGrowthStreak;
  static int _minGrowthBytes = _defaultMinGrowthBytes;

  static MemoryGrowthWindow? _growth;
  static MemoryBudgetWindow? _budget;
  static VmMemoryMonitor? _vm;
  static final Stopwatch _elapsed = Stopwatch();
  static int _generation = 0;
  static String _runId = '';
  static final Map<String, DateTime> _lastReportAt = {};
  static final Map<String, String> _lastEpisode = {};
  static final Set<String> _reportingTypes = {};
  static int? _baselineRss;

  static Future<void> Function(Map<String, dynamic> properties)? _onMemory;
  static int Function()? _rssReader;

  /// 测试注入。
  @visibleForTesting
  static Future<void> Function(String name, Map<String, dynamic> properties)?
      debugOnReport;

  static bool get isStarted => _started;

  /// 启动监测。Web / 不支持 [ProcessInfo] 的平台会直接跳过。
  static void start({
    Duration sampleInterval = _defaultSampleInterval,
    Duration reportCoolDown = _defaultCoolDown,
    int growthStreak = _defaultGrowthStreak,
    int minGrowthBytes = _defaultMinGrowthBytes,
    int pressureBytes = _defaultPressureBytes,
    Duration warmup = const Duration(seconds: 30),
    Duration growthSustain = const Duration(seconds: 30),
    bool enableVmMonitoring = true,
    Future<void> Function(Map<String, dynamic> properties)? onMemory,
    @visibleForTesting int Function()? rssReader,
  }) {
    if (_started) return;
    if (kIsWeb) {
      debugPrint('[ftm] memory monitor skipped on web');
      return;
    }
    if (sampleInterval.inMilliseconds <= 0) {
      debugPrint('[ftm] memory monitor skipped: sampleInterval must be > 0');
      return;
    }
    growthStreak = growthStreak.clamp(2, 60);
    if (minGrowthBytes < 0) minGrowthBytes = 0;

    _sampleInterval = sampleInterval;
    _coolDown = reportCoolDown;
    _growthStreak = growthStreak;
    _minGrowthBytes = minGrowthBytes;
    _onMemory = onMemory;
    _rssReader = rssReader;
    final spacing = Duration(
        milliseconds: (sampleInterval.inMilliseconds ~/ 2).clamp(1, 1 << 40));
    _growth = MemoryGrowthWindow(
      thresholdBytesPerSecond:
          minGrowthBytes / (sampleInterval.inMilliseconds / 1000),
      warmup: warmup,
      window: sampleInterval * (growthStreak + 3),
      minSpan: sampleInterval * growthStreak,
      sustain: growthSustain,
      minSamples: growthStreak + 1,
      minSpacing: spacing,
    );
    _budget = MemoryBudgetWindow(pressureBytes, minSpacing: spacing);
    _elapsed
      ..reset()
      ..start();
    final generation = ++_generation;
    _runId = DateTime.now().microsecondsSinceEpoch.toString();
    _baselineRss = null;
    _lastReportAt.clear();
    _lastEpisode.clear();

    _timer?.cancel();
    _timer = Timer.periodic(sampleInterval, (_) => unawaited(_sample()));

    _started = true;
    if (enableVmMonitoring &&
        !kReleaseMode &&
        rssReader == null &&
        debugOnReport == null) {
      _vm = VmMemoryMonitor(onSignal: (signal) async {
        if (!_started || generation != _generation) return;
        await _emit(
          type: signal['type'] as String,
          severity: signal['severity'] as String,
          rss: _readRss(),
          maxRss: ProcessInfo.maxRss,
          imageCacheBytes: _imageCacheBytes(),
          extra: signal,
        );
      });
      unawaited(_vm!.start());
    }
    debugPrint(
      '[ftm] memory monitor started '
      '(interval=${sampleInterval.inSeconds}s streak=$growthStreak '
      'minGrowth=${_fmtMb(minGrowthBytes)} '
      'pressure=${pressureBytes <= 0 ? 'off' : _fmtMb(pressureBytes)})',
    );
  }

  static Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _started = false;
    _generation++;
    _elapsed.stop();
    final vm = _vm;
    _vm = null;
    _onMemory = null;
    _rssReader = null;
    _growth = null;
    _budget = null;
    await vm?.stop();
  }

  @visibleForTesting
  static Future<void> debugReset() async {
    await stop();
    debugOnReport = null;
    _lastReportAt.clear();
    _reportingTypes.clear();
    _baselineRss = null;
    _sampleInterval = _defaultSampleInterval;
    _coolDown = _defaultCoolDown;
    _growthStreak = _defaultGrowthStreak;
    _minGrowthBytes = _defaultMinGrowthBytes;
  }

  /// 立刻采样一次（演示 / 诊断用）。
  static Future<void> sampleNow() => _sample();

  /// 测试用：手动喂一次 RSS（字节）。
  @visibleForTesting
  static Future<void> debugSampleRss(int rssBytes, {int? atMs}) =>
      _onRss(rssBytes, atMs: atMs);

  static Future<void> _sample() async {
    if (!_started) return;
    try {
      final rss = (_rssReader ?? _readRss)();
      if (rss <= 0) return;
      await _onRss(rss);
    } catch (e) {
      debugPrint('[ftm] memory sample failed: $e');
    }
  }

  static int _readRss() => ProcessInfo.currentRss;

  static Future<void> _onRss(int rss, {int? atMs}) async {
    if (!_started || rss <= 0) return;
    final now = atMs ?? _elapsed.elapsedMilliseconds;
    _baselineRss ??= rss;
    final pressure = _budget?.add(now, rss);
    final growth = _growth?.add(now, rss);

    final imageCacheBytes = _imageCacheBytes();
    final maxRss = ProcessInfo.maxRss;

    // 1) 绝对水位
    if (pressure != null) {
      await _emit(
        type: 'memory_pressure',
        severity: 'pressure',
        rss: rss,
        maxRss: maxRss,
        imageCacheBytes: imageCacheBytes,
        extra: {
          ...pressure,
          'confidence': 'likely',
          'evidence': 'rss_budget',
        },
      );
      return;
    }

    // 2) 连续上涨
    if (growth != null) {
      await _emit(
        type: 'memory_growth',
        severity: 'trend',
        rss: rss,
        maxRss: maxRss,
        imageCacheBytes: imageCacheBytes,
        extra: {
          ...growth,
          'growth_streak': _growthStreak,
          'min_growth_bytes': _minGrowthBytes,
          'sample_interval_ms': _sampleInterval.inMilliseconds,
          'baseline_rss': _baselineRss,
          'confidence': 'suspect',
          'evidence': 'rss_regression',
        },
      );
    }
  }

  static int? _imageCacheBytes() {
    try {
      return PaintingBinding.instance.imageCache.currentSizeBytes;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _emit({
    required String type,
    required String severity,
    required int rss,
    required int maxRss,
    required int? imageCacheBytes,
    Map<String, dynamic>? extra,
  }) async {
    final generation = _generation;
    final detectorKey = '$type:${extra?['resource_class'] ?? ''}';
    final reportingKey = '$generation:$detectorKey';
    final episode = '$_runId:$detectorKey:${extra?['episode_started_ms'] ?? 0}';
    if (_reportingTypes.contains(reportingKey)) return;
    final now = DateTime.now();
    if (_lastEpisode[detectorKey] == episode &&
        _lastReportAt[detectorKey] != null &&
        now.difference(_lastReportAt[detectorKey]!) < _coolDown) {
      return;
    }

    _reportingTypes.add(reportingKey);
    _lastReportAt[detectorKey] = now;
    _lastEpisode[detectorKey] = episode;
    try {
      final route = FastTrackMcpNetwork.currentRoute();
      final props = <String, dynamic>{
        'detector_version': 2,
        'episode_id': episode,
        'observation_scope': 'process',
        'gc_verified': false,
        'leak_confirmed': false,
        'type': type,
        'severity': severity,
        'rss_bytes': rss,
        'rss_mb': double.parse((rss / (1024 * 1024)).toStringAsFixed(2)),
        'max_rss_bytes': maxRss,
        'max_rss_mb': double.parse((maxRss / (1024 * 1024)).toStringAsFixed(2)),
        if (imageCacheBytes != null) 'image_cache_bytes': imageCacheBytes,
        if (route != null && route.isNotEmpty) 'route': route,
        if (_baselineRss != null) ...{
          'baseline_rss_bytes': _baselineRss,
          'delta_from_baseline_bytes': rss - _baselineRss!,
        },
        ...?extra,
      };

      final hook = debugOnReport;
      if (hook != null) {
        await hook(FastTrackMcpEventName.appMemoryLeak, props);
        return;
      }
      await FastTrackMcpDetectSink.track(
        FastTrackMcpEventName.appMemoryLeak,
        properties: props,
      );
      final onMemory = _onMemory;
      if (onMemory != null && _started && generation == _generation) {
        await onMemory(props);
      }
    } catch (e) {
      debugPrint('[ftm] memory report failed: $e');
    } finally {
      _reportingTypes.remove(reportingKey);
    }
  }

  static String _fmtMb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1)}MB';
}
