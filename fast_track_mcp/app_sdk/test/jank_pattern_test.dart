import 'dart:async';
import 'dart:ui';

import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming sample(int at,
        {int delay = 0, int build = 4000, int raster = 4000, int wait = 0}) =>
    FrameTiming(
      vsyncStart: at,
      buildStart: at + delay,
      buildFinish: at + delay + build,
      rasterStart: at + delay + build + wait,
      rasterFinish: at + delay + build + wait + raster,
      rasterFinishWallTime: at + delay + build + wait + raster,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, dynamic>> reports;
  setUp(() {
    reports = [];
    FastTrackMcpJankMonitor.debugOnReport = (_, p) async => reports.add(p);
  });
  tearDown(FastTrackMcpJankMonitor.debugReset);

  void start({Duration warmup = Duration.zero}) {
    FastTrackMcpJankMonitor.start(
        enableFrozenFrameAlerts: true,
        fpsTarget: 60,
        reportInterval: Duration.zero,
        warmup: warmup);
  }

  test('default single long frame does not bypass the pattern gate', () async {
    FastTrackMcpJankMonitor.start(
        fpsTarget: 60, reportInterval: Duration.zero, warmup: Duration.zero);
    FastTrackMcpJankMonitor.debugHandleTimings([sample(0, build: 800000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports, isEmpty);
    FastTrackMcpJankMonitor.debugHandleTimings(
        List.generate(5, (i) => sample(1000000 + i * 50000, build: 40000)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['sustained_jank'], true);
    expect(reports.single['severity'], 'severe');
  });

  test(
      'rolling snapshots overlap, expire old frames, and deduplicate unchanged reads',
      () async {
    start();
    FastTrackMcpJankMonitor.debugHandleTimings(
        List.generate(5, (i) => sample(i * 50000, build: 20000)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    FastTrackMcpJankMonitor.debugHandleTimings([sample(300000, build: 20000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.last['total_frames'], 6);
    final count = reports.length;
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.length, count);
    FastTrackMcpJankMonitor.debugHandleTimings(
        List.generate(5, (i) => sample(11000000 + i * 50000, build: 20000)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.last['total_frames'], 5);
    expect(reports.last['window_mode'], 'rolling');
  });

  test('late UI start counts as jank even when build and raster are fast',
      () async {
    start();
    FastTrackMcpJankMonitor.debugHandleTimings(
        List.generate(5, (i) => sample(i * 50000, delay: i < 3 ? 25000 : 0)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    final report = reports.single;
    expect(report['slow_frames'], 3);
    expect(report['late_start_frames'], 3);
    expect(report['build_slow_frames'], 0);
    expect(report['jank_detected'], true);
    expect(report['jank_rate'], .6);
  });

  test('three scattered mild slow frames among 600 do not raise a pattern',
      () async {
    start();
    FastTrackMcpJankMonitor.debugHandleTimings(List.generate(
        600, (i) => sample(i * 16000, build: i % 200 == 0 ? 20000 : 4000)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports, isEmpty);
  });

  test('three severe frames raise severity even below the ordinary rate gate',
      () async {
    start();
    FastTrackMcpJankMonitor.debugHandleTimings(List.generate(
        100, (i) => sample(i * 50000, build: i < 3 ? 40000 : 4000)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['sustained_jank'], true);
    expect(reports.single['jank_detected'], false);
    expect(reports.single['severity'], 'severe');
  });

  test('fewer than five frames do not establish a non-frozen pattern',
      () async {
    start();
    FastTrackMcpJankMonitor.debugHandleTimings(
        List.generate(4, (i) => sample(i * 50000, build: 40000)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports, isEmpty);
  });

  test('warmup uses frame timestamps even when callbacks arrive as one batch',
      () async {
    start(warmup: const Duration(seconds: 3));
    FastTrackMcpJankMonitor.debugHandleTimings([
      ...List.generate(5, (i) => sample(i * 100000, build: 40000)),
      ...List.generate(5, (i) => sample(3000000 + i * 100000, build: 20000)),
    ]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['total_frames'], 5);
    expect(reports.single['severity'], 'slow');
    expect(reports.single['lifecycle_phase'], 'steady');
  });

  test('startup frozen frames remain observable and identify startup phase',
      () async {
    start(warmup: const Duration(seconds: 3));
    FastTrackMcpJankMonitor.debugHandleTimings([sample(0, build: 800000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.first['type'], 'frozen_frame');
    expect(reports.first['lifecycle_phase'], 'startup');
    expect(reports.last['frozen_reported_separately'], true);
  });

  test('raster pipeline waiting is latency, not processing jank', () async {
    start();
    FastTrackMcpJankMonitor.debugHandleTimings(
        List.generate(5, (i) => sample(i * 50000, wait: 25000)));
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['jank_detected'], false);
    expect(reports.single['slow_frames'], 0);
    expect(reports.single['severity'], 'latency');
  });

  test('batched old and new route frames retain their own route epochs',
      () async {
    start();
    FastTrackMcpJankMonitor.markRoute('/a', atUs: 0);
    FastTrackMcpJankMonitor.markRoute('/b', atUs: 1000000);
    FastTrackMcpJankMonitor.debugHandleTimings([
      ...List.generate(5, (i) => sample(i * 50000, build: 20000)),
      ...List.generate(5, (i) => sample(1000000 + i * 50000, build: 20000)),
    ]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.map((p) => p['route']), ['/a', '/b']);
    expect(reports.every((p) => p['total_frames'] == 5), true);
  });

  test('slow delivery never merges different page visits', () async {
    final release = Completer<void>();
    FastTrackMcpJankMonitor.debugOnReport = (_, p) async {
      reports.add(p);
      if (reports.length == 1) await release.future;
    };
    start();
    final flushes = <Future<void>>[];
    for (var visit = 0; visit < 3; visit++) {
      FastTrackMcpJankMonitor.markRoute(visit == 1 ? '/b' : '/a',
          atUs: visit * 1000000);
      FastTrackMcpJankMonitor.debugHandleTimings(List.generate(
          5, (i) => sample(visit * 1000000 + i * 50000, build: 20000)));
      flushes.add(FastTrackMcpJankMonitor.debugFlushWindow());
    }
    release.complete();
    await Future.wait(flushes);
    expect(reports.map((p) => p['route']), ['/a', '/b', '/a']);
    expect(reports.map((p) => p['route_epoch']).toSet().length, 3);
  });

  test('two page instances with the same route can establish separate epochs',
      () async {
    start();
    FastTrackMcpJankMonitor.markRoute('/detail', atUs: 0);
    FastTrackMcpJankMonitor.markRoute('/detail', atUs: 1000000, force: true);
    FastTrackMcpJankMonitor.debugHandleTimings([
      ...List.generate(5, (i) => sample(i * 50000, build: 20000)),
      ...List.generate(5, (i) => sample(1000000 + i * 50000, build: 20000)),
    ]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.length, 2);
    expect(reports.map((p) => p['route_epoch']).toSet().length, 2);
  });

  test(
      'cooldown-suppressed frozen observations are not marked separately reported',
      () async {
    start();
    FastTrackMcpJankMonitor.debugHandleTimings([sample(0, build: 800000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    FastTrackMcpJankMonitor.debugHandleTimings(
        [sample(1000000, build: 800000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.where((p) => p['type'] == 'frozen_frame').length, 1);
    expect(reports.last['frozen_reported_separately'], false);
  });
}
