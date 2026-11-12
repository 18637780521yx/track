import 'dart:collection';

import 'memory_evidence.dart';

/// VM evidence is separate from RSS. No forced collection is used, and even
/// post-GC growth confirms retention growth, not an unintended reference.
class VmMemoryEvidence {
  final _heap = MemoryGrowthWindow(
    thresholdBytesPerSecond: 512000,
    minSpan: const Duration(seconds: 10),
    sustain: const Duration(seconds: 10),
    window: const Duration(seconds: 60),
    minSamples: 4,
  );
  final _native = MemoryGrowthWindow(
    thresholdBytesPerSecond: 1048576,
    minSpan: const Duration(seconds: 10),
    sustain: const Duration(seconds: 10),
    window: const Duration(seconds: 60),
    minSamples: 4,
  );
  final _floor = MemoryGrowthWindow(
    thresholdBytesPerSecond: 512000,
    warmup: Duration.zero,
    minSpan: const Duration(seconds: 10),
    sustain: Duration.zero,
    window: const Duration(seconds: 60),
    minSamples: 3,
    resetOnDrop: true,
  );
  final _gc = ListQueue<int>();
  final _resources = <String, MemoryGrowthWindow>{};
  int? _firstGcAt, _idleMarkAt, _lastGcAt, _gcEpisode;
  int? _lastHeapGrowthAt;

  List<Map<String, dynamic>> addHeap({
    required int atMs,
    required int heapBytes,
    required int externalBytes,
    required int rssBytes,
  }) {
    if (heapBytes < 0 || externalBytes < 0) return [];
    final result = <Map<String, dynamic>>[];
    final heap = _heap.add(atMs, heapBytes);
    if (heap != null) {
      _lastHeapGrowthAt = atMs;
      result.add(_signal('heap_growing', 'dart_heap_regression', heap,
          heapBytes: heapBytes, externalBytes: externalBytes));
    }
    // RSS includes shared pages and allocator reservations; this subtraction
    // is only a residual estimate, never a measurement of native allocations.
    final residual = rssBytes - heapBytes - externalBytes;
    if (rssBytes > 0 && residual >= 0) {
      final native = _native.add(atMs, residual);
      if (native != null) {
        result.add(_signal(
            'native_memory_growing', 'rss_residual_estimate', native,
            heapBytes: heapBytes, externalBytes: externalBytes)
          ..['confidence'] = 'suspect'
          ..['native_residual_bytes'] = residual);
      }
    }
    return result;
  }

  List<Map<String, dynamic>> addGc({
    required int atMs,
    required String type,
    required String? reason,
    required int? heapUsedAfter,
  }) {
    if (_lastGcAt != null && atMs < _lastGcAt!) return [];
    _lastGcAt = atMs;
    _firstGcAt ??= atMs;
    if (type == 'StartCMark' || type == 'StartConcurrentMark') {
      _idleMarkAt = reason == 'idle' ? atMs : null;
      return [];
    }
    if (!{'Scavenge', 'MarkSweep', 'MarkCompact'}.contains(type)) return [];
    _gc.addLast(atMs);
    while (_gc.isNotEmpty && atMs - _gc.first > 10000) {
      _gc.removeFirst();
    }
    // Bound storage during severe churn; >30 is sufficient evidence.
    while (_gc.length > 1000) {
      _gc.removeFirst();
    }
    final result = <Map<String, dynamic>>[];
    if (_gc.length <= 30) _gcEpisode = null;
    if (atMs - _firstGcAt! >= 30000 && _gc.length > 30) {
      _gcEpisode ??= atMs;
      result.add(_signal('gc_pressure', 'vm_gc_frequency', {
        'episode_started_ms': _gcEpisode,
        'gc_count': _gc.length,
        'window_ms': 10000,
        'gc_rate_per_min': _gc.length * 6,
      }));
    }
    if (type == 'Scavenge') return result;
    final idleMark = _idleMarkAt;
    _idleMarkAt = null;
    final idleFull = reason == 'idle' ||
        (idleMark != null && atMs - idleMark <= 100 && atMs >= idleMark);
    if (atMs - _firstGcAt! < 30000 || !idleFull || heapUsedAfter == null) {
      return result;
    }
    final floor = _floor.add(atMs, heapUsedAfter);
    if (floor != null) {
      _lastHeapGrowthAt = atMs;
      result.add(_signal('heap_retained_growth', 'idle_full_gc_floor', floor,
          heapBytes: heapUsedAfter)
        ..['gc_verified'] = true
        ..['confidence'] = 'strong'
        ..['severity'] = 'retention_suspect');
    }
    return result;
  }

  /// Keys must already be verified dart:async resource classes by the adapter.
  /// Missing classes are zero counts, not silently retained historical values.
  List<Map<String, dynamic>> addResources(int atMs, Map<String, int> counts) {
    final result = <Map<String, dynamic>>[];
    for (final key in {..._resources.keys, ...counts.keys}.take(64)) {
      final tracker = _resources.putIfAbsent(
          key,
          () => MemoryGrowthWindow(
                thresholdBytesPerSecond: 1 / 60,
                warmup: const Duration(seconds: 30),
                window: const Duration(minutes: 3),
                minSpan: const Duration(seconds: 60),
                sustain: Duration.zero,
                minSamples: 4,
                minSpacing: const Duration(seconds: 20),
                resetOnDrop: true,
              ));
      final growth = tracker.add(atMs, counts[key] ?? 0);
      final heapAt = _lastHeapGrowthAt;
      final corroborated =
          heapAt != null && atMs >= heapAt && atMs - heapAt <= 30000;
      if (growth != null &&
          corroborated &&
          (growth['growth_bytes'] as int) >= 3) {
        final signal = _signal('stream_resource_growth', 'vm_resource_counts', {
          ...growth,
          'resource_class': key,
          'instance_count': counts[key] ?? 0,
          'instance_delta': growth['growth_bytes'],
          'instance_rate_per_sec': growth['growth_rate_bytes_per_sec'],
          'corroboration': 'recent_heap_growth',
        });
        // Counts are not byte measurements.
        signal.remove('growth_bytes');
        signal.remove('growth_rate_bytes_per_sec');
        signal.remove('threshold_bytes_per_sec');
        signal['samples'] = (growth['samples'] as List)
            .map((p) => {
                  'at_ms': p['at_ms'],
                  'instances': p['bytes'],
                })
            .toList();
        result.add(signal);
      }
    }
    return result;
  }

  Map<String, dynamic> _signal(
          String type, String evidence, Map<String, dynamic> data,
          {int? heapBytes, int? externalBytes}) =>
      {
        ...data,
        'type': type,
        'severity': 'trend',
        'confidence': 'likely',
        'evidence': evidence,
        'observation_scope': 'isolate',
        'gc_verified': false,
        'leak_confirmed': false,
        if (heapBytes != null) 'heap_bytes': heapBytes,
        if (externalBytes != null) 'external_bytes': externalBytes,
      };
}
