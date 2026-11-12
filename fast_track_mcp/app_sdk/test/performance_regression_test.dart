import 'dart:async';
import 'dart:ui';

import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming frame(int build, int raster, {int wait = 0}) => FrameTiming(
      vsyncStart: 0,
      buildStart: 0,
      buildFinish: build,
      rasterStart: build + wait,
      rasterFinish: build + wait + raster,
      rasterFinishWallTime: build + wait + raster,
    );

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fast_track_mcp/anr');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return null;
    });
    TransitionLeakTracker.instance.clear();
    TransitionLeakTracker.instance.configure(
        enabled: true,
        alertOnWeakRef: true,
        requireMultiRound: true,
        settleMs: 0);
  });

  tearDown(() async {
    await FastTrackMcpJankMonitor.debugReset();
    await FastTrackMcpMemoryMonitor.debugReset();
    await FastTrackMcpAnrWatchdog.debugReset();
    TransitionLeakTracker.instance.clear();
    LeakOnline.instance.reset();
    binding.platformDispatcher.displays.first.resetRefreshRate();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('a frozen report cannot discard its aggregate window', () async {
    final release = Completer<void>();
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpJankMonitor.debugOnReport = (_, props) async {
      reports.add(props);
      if (reports.length == 1) await release.future;
    };
    FastTrackMcpJankMonitor.start(fpsTarget: 60, reportInterval: Duration.zero);
    FastTrackMcpJankMonitor.debugHandleTimings([frame(700000, 100000)]);
    final flushed = FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.map((p) => p['type']), ['frozen_frame']);
    release.complete();
    await flushed;
    expect(reports.map((p) => p['type']), ['frozen_frame', 'frame_window']);
    expect(reports.last['frozen_frames'], 1);
  });

  test('backpressure merges pending windows without losing counts', () async {
    final release = Completer<void>();
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpJankMonitor.debugOnReport = (_, props) async {
      reports.add(props);
      if (reports.length == 1) await release.future;
    };
    FastTrackMcpJankMonitor.start(
        fpsTarget: 60, reportInterval: Duration.zero, minSlowFramesToReport: 1);
    final futures = <Future<void>>[];
    for (var i = 0; i < 4; i++) {
      FastTrackMcpJankMonitor.debugHandleTimings([frame(20000, 2000)]);
      futures.add(FastTrackMcpJankMonitor.debugFlushWindow());
    }
    release.complete();
    await Future.wait(futures);
    expect(reports, hasLength(2));
    expect(reports.last['total_frames'], 3);
    expect(reports.last['slow_frames'], 3);
    expect(reports.last['jank_rate'], 1);
  });

  test('pipeline latency alone does not count as a slow processing stage',
      () async {
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpJankMonitor.debugOnReport = (_, p) async => reports.add(p);
    FastTrackMcpJankMonitor.start(
        fpsTarget: 60, reportInterval: Duration.zero, minSlowFramesToReport: 1);
    FastTrackMcpJankMonitor.debugHandleTimings([
      frame(10000, 10000, wait: 10000),
      frame(20000, 1000),
    ]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['total_frames'], 2);
    expect(reports.single['slow_frames'], 1);
    expect(reports.single['build_slow_frames'], 1);
    expect(reports.single['high_latency_frames'], 2);
  });

  test('120 Hz budget detects a 10 ms build', () async {
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpJankMonitor.debugOnReport = (_, p) async => reports.add(p);
    FastTrackMcpJankMonitor.start(
        fpsTarget: 120,
        reportInterval: Duration.zero,
        minSlowFramesToReport: 1);
    FastTrackMcpJankMonitor.debugHandleTimings([frame(10000, 1000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['slow_frames'], 1);
    expect(reports.single['budget_ms'], closeTo(8.33, .01));
  });

  test('automatic refresh budget follows display changes', () async {
    final display = binding.platformDispatcher.displays.first;
    display.refreshRate = 60;
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpJankMonitor.debugOnReport = (_, p) async => reports.add(p);
    FastTrackMcpJankMonitor.start(
        reportInterval: Duration.zero, minSlowFramesToReport: 1);
    FastTrackMcpJankMonitor.debugHandleTimings([frame(10000, 1000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports, isEmpty);
    display.refreshRate = 120;
    FastTrackMcpJankMonitor.debugHandleTimings([frame(10000, 1000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['fps_target'], 120);
    expect(reports.single['slow_frames'], 1);
  });

  test('latency-only windows retain zero processing jank rate', () async {
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpJankMonitor.debugOnReport = (_, p) async => reports.add(p);
    FastTrackMcpJankMonitor.start(
        fpsTarget: 60, reportInterval: Duration.zero, minSlowFramesToReport: 1);
    FastTrackMcpJankMonitor.debugHandleTimings([frame(10000, 10000)]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    expect(reports.single['severity'], 'latency');
    expect(reports.single['slow_frames'], 0);
    expect(reports.single['jank_rate'], 0);
    expect(reports.single['high_latency_frames'], 1);
  });

  test('pressure escalates even while a growth report is pending', () async {
    final release = Completer<void>();
    final types = <String>[];
    FastTrackMcpMemoryMonitor.debugOnReport = (_, p) async {
      types.add(p['type'] as String);
      if (p['type'] == 'memory_growth') await release.future;
    };
    FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(hours: 1),
        growthStreak: 2,
        minGrowthBytes: 1,
        warmup: Duration.zero,
        growthSustain: Duration.zero,
        pressureBytes: 100);
    await FastTrackMcpMemoryMonitor.debugSampleRss(10, atMs: 0);
    await FastTrackMcpMemoryMonitor.debugSampleRss(20, atMs: 3600000);
    final growth = FastTrackMcpMemoryMonitor.debugSampleRss(30, atMs: 7200000);
    for (var i = 3; i < 8; i++) {
      await FastTrackMcpMemoryMonitor.debugSampleRss(110, atMs: i * 3600000);
    }
    release.complete();
    await growth;
    expect(types, ['memory_growth', 'memory_pressure']);
  });

  test('zero growth threshold still requires an actual increase', () async {
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpMemoryMonitor.debugOnReport = (_, p) async => reports.add(p);
    FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(hours: 1),
        growthStreak: 2,
        minGrowthBytes: 0,
        pressureBytes: 0);
    for (var i = 0; i < 3; i++) {
      await FastTrackMcpMemoryMonitor.debugSampleRss(10);
    }
    expect(reports, isEmpty);
  });

  test('leak probe keeps distinct route suffixes isolated', () async {
    final resource = Object();
    final tracker = TransitionLeakTracker.instance;
    tracker.track(resource, route: '/detail#first');
    final probe = await tracker.probeAfterPop(poppedRoute: '/detail#second');
    expect(probe.alive, isEmpty);
    expect(resource, isNotNull);
  });

  test('different logical routes cannot confirm each other across rounds',
      () async {
    final first = Object();
    final second = Object();
    final tracker = TransitionLeakTracker.instance;
    tracker.track(first, route: '/tabs#first');
    tracker.track(second, route: '/tabs#second');
    final a = await tracker.probeAfterPop(poppedRoute: '/tabs#first');
    final b = await tracker.probeAfterPop(poppedRoute: '/tabs#second');
    expect(a.multiRoundConfirmed, false);
    expect(b.multiRoundConfirmed, false);
    expect([first, second], hasLength(2));
  });

  test('one observation is a suspicion and requires confirmation by default',
      () async {
    final resource = Object();
    final tracker = TransitionLeakTracker.instance;
    tracker.track(resource, route: '/detail');
    final first = await tracker.probeAfterPop(poppedRoute: '/detail');
    expect(first.hasWeakRefLeak, true);
    expect(first.hasLeak, false);
    expect(tracker.shouldAlertLeak(first), false);
    final second = await tracker.probeAfterPop(poppedRoute: '/detail');
    expect(tracker.shouldAlertLeak(second), true);
    expect(second.toJson()['gc_verified'], false);
    tracker.configure(enabled: false);
    expect(tracker.shouldAlertLeak(second), false);
    expect(resource, isNotNull);
  });

  test('online reporting honors alertOnWeakRef rather than just liveness',
      () async {
    final resource = Object();
    final events = <Map<String, dynamic>>[];
    LeakOnline.instance
        .configure(enabled: true, sampleRate: 1, onEvent: events.add);
    TransitionLeakTracker.instance
        .configure(alertOnWeakRef: false, requireMultiRound: false);
    TransitionLeakTracker.instance.track(resource, route: '/audit');
    TransitionLedger.instance.onPush('/audit');
    TransitionLedger.instance.onPop('/audit');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.where((e) => e['type'] == 'transition_leak'), isEmpty);
    expect(resource, isNotNull);
  });

  test('historical ANRs bypass realtime cooldown and ack only durable records',
      () async {
    final written = <String>[];
    FastTrackMcpAnrWatchdog.debugOnReport = (_, __) async {};
    await FastTrackMcpAnrWatchdog.debugEmit({'blocked_ms': 5000});
    FastTrackMcpAnrWatchdog.debugPersistHistory = (id, props) async {
      written.add(id);
      return id != 'anr-failed';
    };
    await Future.wait([
      FastTrackMcpAnrWatchdog.debugEmit({'anr_id': 'anr-first'}),
      FastTrackMcpAnrWatchdog.debugEmit({'anr_id': 'anr-second'}),
      FastTrackMcpAnrWatchdog.debugEmit({'anr_id': 'anr-failed'}),
    ]);
    expect(written, ['anr-first', 'anr-second', 'anr-failed']);
    expect(
        calls
            .where((c) => c.method == 'ackAnr')
            .map((c) => c.arguments['anr_id']),
        ['anr-first', 'anr-second']);
  });

  test('historical ANR replay retries ack without inserting twice', () async {
    var writes = 0;
    var acks = 0;
    FastTrackMcpAnrWatchdog.debugPersistHistory = (_, __) async {
      writes++;
      return true;
    };
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'ackAnr' && ++acks == 1) {
        throw PlatformException(code: 'ack_failed');
      }
      return null;
    });
    await FastTrackMcpAnrWatchdog.debugEmit({'anr_id': 'anr-repeat'});
    await FastTrackMcpAnrWatchdog.debugEmit({'anr_id': 'anr-repeat'});
    expect(writes, 1);
    expect(acks, 2);
  });
}
