import 'dart:collection';

/// Bounded, time-based regression. A rising sample is evidence of growth,
/// never proof that an object leaked. Inspired by Sleuth's windowed detectors.
class MemoryGrowthWindow {
  MemoryGrowthWindow({
    required this.thresholdBytesPerSecond,
    this.warmup = const Duration(seconds: 30),
    this.window = const Duration(minutes: 3),
    this.minSpan = const Duration(seconds: 60),
    this.sustain = const Duration(seconds: 30),
    this.minSamples = 5,
    this.minSpacing = const Duration(seconds: 1),
    this.resetOnDrop = false,
  });

  final double thresholdBytesPerSecond;
  final Duration warmup, window, minSpan, sustain, minSpacing;
  final int minSamples;
  final bool resetOnDrop;
  final _points = ListQueue<({int at, int bytes})>();
  int? _firstAt, _aboveSince, _episodeAt;

  void clear() {
    _points.clear();
    _firstAt = _aboveSince = _episodeAt = null;
  }

  Map<String, dynamic>? add(int atMs, int bytes) {
    if (bytes < 0) return null;
    if (_points.isNotEmpty && atMs < _points.last.at) clear();
    _firstAt ??= atMs;
    if (atMs - _firstAt! < warmup.inMilliseconds) return null;
    if (_points.isNotEmpty) {
      final gap = atMs - _points.last.at;
      if (gap < minSpacing.inMilliseconds || gap <= 0) return null;
      if (gap > window.inMilliseconds) {
        _points.clear();
        _aboveSince = _episodeAt = null;
      } else if (resetOnDrop && bytes < _points.last.bytes) {
        _points.clear();
        _aboveSince = _episodeAt = null;
      }
    }
    _points.addLast((at: atMs, bytes: bytes));
    while (_points.length > 120 ||
        (_points.length > 1 &&
            atMs - _points.first.at > window.inMilliseconds)) {
      _points.removeFirst();
    }
    if (_points.length < minSamples ||
        atMs - _points.first.at < minSpan.inMilliseconds) {
      return null;
    }
    // Center the coordinates to avoid floating-point cancellation on epoch ms.
    final origin = _points.first;
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (final point in _points) {
      final x = (point.at - origin.at) / 1000;
      final y = (point.bytes - origin.bytes).toDouble();
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final n = _points.length;
    final denominator = n * sxx - sx * sx;
    final slope = denominator > 0 ? (n * sxy - sx * sy) / denominator : 0.0;
    // Check the newer half too. This tolerates GC sawteeth but prevents an
    // old burst from sustaining an episode after a plateau.
    final previous = _points.elementAt(n ~/ 2);
    final recentSlope = (bytes - previous.bytes) * 1000 / (atMs - previous.at);
    if (slope <= thresholdBytesPerSecond ||
        recentSlope <= thresholdBytesPerSecond / 2 ||
        bytes <= origin.bytes) {
      _aboveSince = _episodeAt = null;
      return null;
    }
    _aboveSince ??= atMs;
    if (atMs - _aboveSince! < sustain.inMilliseconds) return null;
    _episodeAt ??= _aboveSince;
    return {
      'episode_started_ms': _episodeAt,
      'growth_bytes': bytes - origin.bytes,
      'growth_rate_bytes_per_sec': slope,
      'threshold_bytes_per_sec': thresholdBytesPerSecond,
      'window_ms': atMs - origin.at,
      'sustained_ms': atMs - _aboveSince!,
      'sample_count': n,
      'samples': _points.map((p) => {'at_ms': p.at, 'bytes': p.bytes}).toList(),
    };
  }
}

/// Four of five spaced samples must exceed the budget. Four of five below
/// 90% of the budget are required to end an episode (hysteresis).
class MemoryBudgetWindow {
  MemoryBudgetWindow(this.budgetBytes, {required this.minSpacing});
  final int budgetBytes;
  final Duration minSpacing;
  final _samples = ListQueue<int>();
  int? _lastAt, _episodeAt;

  Map<String, dynamic>? add(int atMs, int bytes) {
    if (budgetBytes <= 0 || bytes <= 0) return null;
    if (_lastAt != null) {
      if (atMs <= _lastAt! || atMs - _lastAt! < minSpacing.inMilliseconds) {
        return null;
      }
      if (atMs - _lastAt! > minSpacing.inMilliseconds * 10) {
        _samples.clear();
        _episodeAt = null;
      }
    }
    _lastAt = atMs;
    _samples.addLast(bytes);
    if (_samples.length > 5) _samples.removeFirst();
    if (_samples.length < 5) return null;
    final hits = _samples.where((v) => v >= budgetBytes).length;
    if (_samples.where((v) => v < budgetBytes * .9).length >= 4) {
      _episodeAt = null;
    }
    if (hits < 4) return null;
    _episodeAt ??= atMs;
    return {
      'episode_started_ms': _episodeAt,
      'pressure_bytes': budgetBytes,
      'over_pressure_bytes': (bytes - budgetBytes).clamp(0, bytes),
      'budget_hits': hits,
      'budget_samples': _samples.length,
    };
  }
}
