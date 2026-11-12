import 'package:fast_track_mcp/src/detect/memory_evidence.dart';
import 'package:fast_track_mcp/src/detect/memory_monitor.dart';
import 'package:fast_track_mcp/src/detect/vm_memory_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mib = 1024 * 1024;
  MemoryGrowthWindow window({Duration warmup = Duration.zero}) =>
      MemoryGrowthWindow(
        thresholdBytesPerSecond: 100000,
        warmup: warmup,
        window: const Duration(seconds: 60),
        minSpan: const Duration(seconds: 20),
        sustain: const Duration(seconds: 10),
        minSamples: 4,
      );

  test('startup burst followed by a cache plateau is not sustained growth', () {
    final detector = window(warmup: const Duration(seconds: 30));
    for (var second = 0; second <= 120; second += 5) {
      final bytes = second < 30 ? second * 10 * mib : 300 * mib;
      expect(detector.add(second * 1000, bytes), isNull);
    }
  });

  test('regression tolerates sawtooth collection dips', () {
    final detector = window();
    final signals = <Map<String, dynamic>>[];
    for (var i = 0; i < 20; i++) {
      final value = 100 * mib + i * 2 * mib - (i.isOdd ? 3 * mib : 0);
      final result = detector.add(i * 5000, value);
      if (result != null) signals.add(result);
    }
    expect(signals, isNotEmpty);
    expect(signals.last['growth_rate_bytes_per_sec'], greaterThan(100000));
    expect(signals.last['window_ms'], lessThanOrEqualTo(60000));
  });

  test('irregular timestamps measure bytes per second, not bytes per call', () {
    final detector = window();
    Map<String, dynamic>? signal;
    for (final second in [0, 4, 11, 20, 31, 43]) {
      signal = detector.add(second * 1000, 10 * mib + second * 200000);
    }
    expect(signal?['growth_rate_bytes_per_sec'], closeTo(200000, .01));
    expect(signal?['sustained_ms'], 23000);
  });

  test('manual burst sampling cannot manufacture a growth window', () {
    final detector = window();
    for (var i = 0; i < 1000; i++) {
      expect(detector.add(i, i * mib), isNull);
    }
  });

  test('missing measurements do not bridge a stale trend', () {
    final detector = window();
    for (var i = 0; i <= 6; i++) {
      detector.add(i * 5000, i * mib);
    }
    expect(detector.add(300000, 200 * mib), isNull);
    expect(detector.add(305000, 201 * mib), isNull);
  });

  test('pressure requires 4 of 5 and recovers with hysteresis', () {
    final detector =
        MemoryBudgetWindow(100, minSpacing: const Duration(seconds: 1));
    var second = 0;
    Map<String, dynamic>? feed(int bytes) =>
        detector.add(second++ * 1000, bytes);
    for (final value in [110, 20, 30, 40, 50]) {
      expect(feed(value), isNull);
    }
    Map<String, dynamic>? first;
    for (final value in [110, 110, 110, 110]) {
      first = feed(value);
    }
    expect(first?['budget_hits'], 4);
    final firstEpisode = first!['episode_started_ms'];
    for (var i = 0; i < 5; i++) {
      feed(95);
    }
    Map<String, dynamic>? held;
    for (var i = 0; i < 5; i++) {
      held = feed(110);
    }
    expect(held?['episode_started_ms'], firstEpisode);
    for (var i = 0; i < 5; i++) {
      feed(80);
    }
    Map<String, dynamic>? next;
    for (var i = 0; i < 5; i++) {
      next = feed(110);
    }
    expect(next?['episode_started_ms'], isNot(firstEpisode));
  });

  test('rapid calls and a disabled budget do not trigger pressure', () {
    final detector =
        MemoryBudgetWindow(100, minSpacing: const Duration(seconds: 1));
    final disabled = MemoryBudgetWindow(0, minSpacing: Duration.zero);
    for (var i = 0; i < 100; i++) {
      expect(detector.add(i, 200), isNull);
      expect(disabled.add(i * 1000, 200), isNull);
    }
  });

  test('only fresh idle full GC observations support retained heap growth', () {
    final detector = VmMemoryEvidence();
    detector.addGc(atMs: 0, type: 'Scavenge', reason: null, heapUsedAfter: 0);
    for (var i = 0; i < 5; i++) {
      expect(
          detector.addGc(
              atMs: 30000 + i * 5000,
              type: 'Scavenge',
              reason: 'idle',
              heapUsedAfter: i * 4 * mib),
          isEmpty);
    }
    for (var i = 0; i < 3; i++) {
      expect(
          detector.addGc(
              atMs: 60000 + i * 5000,
              type: 'MarkSweep',
              reason: 'debugging',
              heapUsedAfter: i * 4 * mib),
          isEmpty);
    }
    Map<String, dynamic>? signal;
    for (var i = 0; i < 3; i++) {
      final signals = detector.addGc(
          atMs: 90000 + i * 5000,
          type: 'MarkSweep',
          reason: 'idle',
          heapUsedAfter: (10 + i * 4) * mib);
      if (signals.isNotEmpty) signal = signals.single;
    }
    expect(signal?['type'], 'heap_retained_growth');
    expect(signal?['gc_verified'], true);
    expect(signal?['leak_confirmed'], false);
    expect(signal?['confidence'], 'strong');
    expect(
        detector.addGc(
            atMs: 105000,
            type: 'MarkSweep',
            reason: 'idle',
            heapUsedAfter: mib),
        isEmpty);
  });

  test('high GC frequency remains distinct from retained heap growth', () {
    final detector = VmMemoryEvidence();
    detector.addGc(
        atMs: 0, type: 'Scavenge', reason: null, heapUsedAfter: null);
    final signals = <Map<String, dynamic>>[];
    for (var i = 0; i < 35; i++) {
      signals.addAll(detector.addGc(
          atMs: 40000 + i * 100,
          type: 'Scavenge',
          reason: 'new space',
          heapUsedAfter: null));
    }
    expect(signals, isNotEmpty);
    expect(
        signals.every(
            (s) => s['type'] == 'gc_pressure' && s['gc_verified'] == false),
        true);
  });

  test('resource counts have instance units and disappearing classes reset',
      () {
    final detector = VmMemoryEvidence();
    final signals = <Map<String, dynamic>>[];
    for (var second = 0; second <= 120; second += 5) {
      detector.addHeap(
          atMs: second * 1000,
          heapBytes: (100 + second) * mib,
          externalBytes: 0,
          rssBytes: (200 + second) * mib);
      if (second % 30 == 0) {
        signals.addAll(detector
            .addResources(second * 1000, {'dart:async::_Timer': second ~/ 15}));
      }
    }
    final signal = signals.single;
    expect(signal['instance_delta'], 6);
    expect(signal.containsKey('growth_bytes'), false);
    expect(signal['type'], 'stream_resource_growth');
    expect(detector.addResources(150000, {}), isEmpty);
    expect(detector.addResources(180000, {'dart:async::_Timer': 1}), isEmpty);
  });

  test('resource counts alone do not report without corroborating heap growth',
      () {
    final detector = VmMemoryEvidence();
    for (var i = 0; i < 10; i++) {
      expect(detector.addResources(i * 30000, {'dart:async::_Timer': i * 100}),
          isEmpty);
    }
  });

  test('Dart heap growth is not evidence of a native leak', () {
    final detector = VmMemoryEvidence();
    final signals = <Map<String, dynamic>>[];
    for (var i = 0; i < 20; i++) {
      signals.addAll(detector.addHeap(
          atMs: i * 5000,
          heapBytes: (100 + i * 4) * mib,
          externalBytes: 10 * mib,
          rssBytes: (200 + i * 4) * mib));
    }
    expect(signals.any((s) => s['type'] == 'heap_growing'), true);
    expect(signals.any((s) => s['type'] == 'native_memory_growing'), false);
  });

  test('monitor resets episodes after recovery and rejects samples after stop',
      () async {
    final signals = <Map<String, dynamic>>[];
    FastTrackMcpMemoryMonitor.debugOnReport = (_, p) async => signals.add(p);
    FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(seconds: 1),
        pressureBytes: 100,
        enableVmMonitoring: false);
    for (var i = 0; i < 5; i++) {
      await FastTrackMcpMemoryMonitor.debugSampleRss(200, atMs: i * 1000);
    }
    for (var i = 5; i < 10; i++) {
      await FastTrackMcpMemoryMonitor.debugSampleRss(50, atMs: i * 1000);
    }
    for (var i = 10; i < 15; i++) {
      await FastTrackMcpMemoryMonitor.debugSampleRss(200, atMs: i * 1000);
    }
    expect(signals.length, 2);
    expect(signals[0]['episode_id'], isNot(signals[1]['episode_id']));
    await FastTrackMcpMemoryMonitor.stop();
    await FastTrackMcpMemoryMonitor.debugSampleRss(1000, atMs: 15000);
    expect(signals.length, 2);
    await FastTrackMcpMemoryMonitor.debugReset();
  });
}
