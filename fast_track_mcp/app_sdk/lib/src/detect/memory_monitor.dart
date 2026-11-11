import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../network/network_capture.dart';
import 'detect_sink.dart';
import 'event_names.dart';

/// 内存泄漏 / 内存压力启发式监测（生产可用、轻量）。
///
/// **不是**对象级 WeakRef 根因分析（那是 perf-agent / DevTools 的活）。
/// 这里定期采样进程 RSS（[ProcessInfo.currentRss]），识别：
/// - **growth**：连续 N 次采样单调上涨且每次超过最小增量 → 疑似泄漏
/// - **pressure**：RSS 超过绝对水位
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
  static int _pressureBytes = _defaultPressureBytes;

  static final ListQueue<int> _rssHistory = ListQueue<int>();
  static final Map<String, DateTime> _lastReportAt = {};
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
    Future<void> Function(Map<String, dynamic> properties)? onMemory,
    @visibleForTesting int Function()? rssReader,
  }) {
    if (_started) return;
    if (kIsWeb) {
      debugPrint('[ftm] memory monitor skipped on web');
      return;
    }
    if (sampleInterval <= Duration.zero) {
      debugPrint('[ftm] memory monitor skipped: sampleInterval must be > 0');
      return;
    }
    if (growthStreak < 2) growthStreak = 2;
    if (minGrowthBytes < 0) minGrowthBytes = 0;

    _sampleInterval = sampleInterval;
    _coolDown = reportCoolDown;
    _growthStreak = growthStreak;
    _minGrowthBytes = minGrowthBytes;
    _pressureBytes = pressureBytes;
    _onMemory = onMemory;
    _rssReader = rssReader;
    _rssHistory.clear();
    _baselineRss = null;
    _lastReportAt.clear();

    _timer?.cancel();
    _timer = Timer.periodic(sampleInterval, (_) => unawaited(_sample()));

    _started = true;
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
    _onMemory = null;
    _rssReader = null;
    _rssHistory.clear();
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
    _pressureBytes = _defaultPressureBytes;
  }

  /// 立刻采样一次（演示 / 诊断用）。
  static Future<void> sampleNow() => _sample();

  /// 测试用：手动喂一次 RSS（字节）。
  @visibleForTesting
  static Future<void> debugSampleRss(int rssBytes) => _onRss(rssBytes);

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

  static Future<void> _onRss(int rss) async {
    _baselineRss ??= rss;
    _rssHistory.addLast(rss);
    while (_rssHistory.length > _growthStreak + 1) {
      _rssHistory.removeFirst();
    }

    final imageCacheBytes = _imageCacheBytes();
    final maxRss = ProcessInfo.maxRss;

    // 1) 绝对水位
    if (_pressureBytes > 0 && rss >= _pressureBytes) {
      await _emit(
        type: 'memory_pressure',
        severity: 'pressure',
        rss: rss,
        maxRss: maxRss,
        imageCacheBytes: imageCacheBytes,
        extra: {
          'pressure_bytes': _pressureBytes,
          'over_pressure_bytes': rss - _pressureBytes,
        },
      );
      return;
    }

    // 2) 连续上涨
    if (_rssHistory.length >= _growthStreak + 1 && _isSustainedGrowth()) {
      final first = _rssHistory.first;
      final last = _rssHistory.last;
      await _emit(
        type: 'memory_growth',
        severity: 'leak_suspect',
        rss: rss,
        maxRss: maxRss,
        imageCacheBytes: imageCacheBytes,
        extra: {
          'growth_bytes': last - first,
          'growth_streak': _growthStreak,
          'min_growth_bytes': _minGrowthBytes,
          'sample_interval_ms': _sampleInterval.inMilliseconds,
          'window_ms': _sampleInterval.inMilliseconds * _growthStreak,
          'baseline_rss': _baselineRss,
          'samples': List<int>.from(_rssHistory),
        },
      );
    }
  }

  static bool _isSustainedGrowth() {
    final list = _rssHistory.toList(growable: false);
    // 需要 growthStreak 段增量 → growthStreak+1 个点
    if (list.length < _growthStreak + 1) return false;
    final start = list.length - (_growthStreak + 1);
    for (var i = start; i < list.length - 1; i++) {
      final delta = list[i + 1] - list[i];
      if (delta <= 0 || delta < _minGrowthBytes) return false;
    }
    return true;
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
    if (_reportingTypes.contains(type)) return;
    final now = DateTime.now();
    if (_lastReportAt[type] != null &&
        now.difference(_lastReportAt[type]!) < _coolDown) {
      return;
    }

    _reportingTypes.add(type);
    _lastReportAt[type] = now;
    try {
      final route = FastTrackMcpNetwork.currentRoute();
      final props = <String, dynamic>{
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
      if (onMemory != null) {
        await onMemory(props);
      }
    } catch (e) {
      debugPrint('[ftm] memory report failed: $e');
    } finally {
      _reportingTypes.remove(type);
    }
  }

  static String _fmtMb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1)}MB';
}
