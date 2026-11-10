import 'dart:ui';

import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await FastTrackMcpCrashHandler.debugReset();
    await FastTrackMcpAnrWatchdog.debugReset();
    await FastTrackMcpJankMonitor.debugReset();
    await FastTrackMcpMemoryMonitor.debugReset();
  });

  group('FastTrackMcpEventName', () {
    test('stability event names are stable', () {
      expect(FastTrackMcpEventName.appCrash, 'app_crash');
      expect(FastTrackMcpEventName.appError, 'app_error');
      expect(FastTrackMcpEventName.appAnr, 'app_anr');
      expect(FastTrackMcpEventName.appJank, 'app_jank');
      expect(FastTrackMcpEventName.appMemoryLeak, 'app_memory_leak');
    });
  });

  group('FastTrackMcpCrashHandler', () {
    test('captureException reports app_error via debugOnReport', () async {
      String? name;
      Map<String, dynamic>? props;
      FastTrackMcpCrashHandler.debugOnReport = (n, p) async {
        name = n;
        props = p;
      };

      await FastTrackMcpCrashHandler.captureException(
        StateError('handled'),
        stackTrace: StackTrace.current,
      );

      expect(name, FastTrackMcpEventName.appError);
      expect(props?['is_fatal'], isFalse);
      expect(props?['type'], 'captured');
      expect(props?['message'], contains('handled'));
      expect(props?['stack'], isNotEmpty);
    });

    test('captureException fatal reports app_crash', () async {
      String? name;
      FastTrackMcpCrashHandler.debugOnReport = (n, _) async => name = n;

      await FastTrackMcpCrashHandler.captureException(
        Exception('fatal-ish'),
        fatal: true,
      );

      expect(name, FastTrackMcpEventName.appCrash);
    });

    test('captureMessage uses CaptureMessage exception_type', () async {
      Map<String, dynamic>? props;
      FastTrackMcpCrashHandler.debugOnReport = (_, p) async => props = p;

      await FastTrackMcpCrashHandler.captureMessage('note only');

      expect(props?['exception_type'], 'CaptureMessage');
      expect(props?['message'], 'note only');
      expect(props?['is_fatal'], isFalse);
    });

    test('FlutterError.onError hook reports nonfatal app_error', () async {
      final reports = <String>[];
      FastTrackMcpCrashHandler.debugOnReport = (n, _) async => reports.add(n);
      FastTrackMcpCrashHandler.install();

      FlutterError.reportError(
        FlutterErrorDetails(
          exception: Exception('from FlutterError'),
          stack: StackTrace.current,
          library: 'detect_test',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(reports, contains(FastTrackMcpEventName.appError));
    });

    test('dedupes identical errors within window', () async {
      var count = 0;
      FastTrackMcpCrashHandler.debugOnReport = (_, __) async => count++;
      FastTrackMcpCrashHandler.install();

      final details = FlutterErrorDetails(
        exception: Exception('dup'),
        stack: StackTrace.current,
      );
      FlutterError.reportError(details);
      FlutterError.reportError(details);
      await Future<void>.delayed(Duration.zero);

      expect(count, 1);
    });
  });

  group('FastTrackMcpAnrWatchdog', () {
    test('debugEmit reports app_anr', () async {
      String? name;
      Map<String, dynamic>? props;
      FastTrackMcpAnrWatchdog.debugOnReport = (n, p) async {
        name = n;
        props = p;
      };

      await FastTrackMcpAnrWatchdog.debugEmit({
        'blocked_ms': 5000,
        'anr_source': 'android_watchdog',
        'stack': 'main blocked',
        'is_fatal': false,
        'platform': 'android',
      });

      expect(name, FastTrackMcpEventName.appAnr);
      expect(props?['anr_source'], 'android_watchdog');
      expect(props?['blocked_ms'], 5000);
      expect(props?['stack'], 'main blocked');
      expect(props?['exception_type'], 'ApplicationNotResponding');
    });

    test('cooldown suppresses burst', () async {
      var count = 0;
      FastTrackMcpAnrWatchdog.debugOnReport = (_, __) async => count++;

      await FastTrackMcpAnrWatchdog.debugEmit({
        'blocked_ms': 1000,
        'anr_source': 'test',
      });
      await FastTrackMcpAnrWatchdog.debugEmit({
        'blocked_ms': 1000,
        'anr_source': 'test',
      });

      expect(count, 1);
    });

    test('start soft on desktop, stop cleans up', () async {
      await FastTrackMcpAnrWatchdog.start(
        timeout: const Duration(seconds: 30),
      );
      expect(FastTrackMcpAnrWatchdog.isStarted, isTrue);
      // CI/desktop → soft；真机插件可用时可能是 native。
      expect(
        FastTrackMcpAnrWatchdog.mode,
        anyOf('soft', 'native'),
      );
      await FastTrackMcpAnrWatchdog.stop();
      expect(FastTrackMcpAnrWatchdog.isStarted, isFalse);
      expect(FastTrackMcpAnrWatchdog.mode, 'off');
    });
  });

  group('FastTrackMcpJankMonitor', () {
    FrameTiming timing({
      required int buildUs,
      required int rasterUs,
    }) {
      final buildStart = 0;
      final buildFinish = buildUs;
      final rasterStart = buildFinish;
      final rasterFinish = rasterStart + rasterUs;
      return FrameTiming(
        vsyncStart: 0,
        buildStart: buildStart,
        buildFinish: buildFinish,
        rasterStart: rasterStart,
        rasterFinish: rasterFinish,
        rasterFinishWallTime: rasterFinish,
      );
    }

    test('window flush reports slow frames as app_jank', () async {
      Map<String, dynamic>? props;
      FastTrackMcpJankMonitor.debugOnReport = (_, p) async => props = p;

      FastTrackMcpJankMonitor.start(
        fpsTarget: 60,
        reportInterval: Duration.zero,
        minSlowFramesToReport: 2,
        frozenFrameThreshold: const Duration(seconds: 10),
      );

      // ~25ms frames → slow under 16.7ms budget
      final slow = timing(buildUs: 20000, rasterUs: 5000);
      FastTrackMcpJankMonitor.debugHandleTimings([slow, slow, slow]);
      await FastTrackMcpJankMonitor.debugFlushWindow();

      expect(props?['type'], 'frame_window');
      expect(props?['severity'], 'slow');
      expect(props?['slow_frames'], greaterThanOrEqualTo(2));
    });

    test('frozen frame reports immediately', () async {
      Map<String, dynamic>? props;
      FastTrackMcpJankMonitor.debugOnReport = (_, p) async => props = p;

      FastTrackMcpJankMonitor.start(
        fpsTarget: 60,
        frozenFrameThreshold: const Duration(milliseconds: 700),
        reportInterval: Duration.zero,
      );

      // 800ms total
      FastTrackMcpJankMonitor.debugHandleTimings([
        timing(buildUs: 700000, rasterUs: 100000),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(props?['type'], 'frozen_frame');
      expect(props?['severity'], 'frozen');
      expect((props?['total_ms'] as num), greaterThanOrEqualTo(700));
    });

    test('below threshold does not flush window', () async {
      var called = false;
      FastTrackMcpJankMonitor.debugOnReport = (_, __) async => called = true;

      FastTrackMcpJankMonitor.start(
        fpsTarget: 60,
        minSlowFramesToReport: 3,
        reportInterval: Duration.zero,
        frozenFrameThreshold: const Duration(seconds: 10),
      );

      // ~5ms frames — not slow
      FastTrackMcpJankMonitor.debugHandleTimings([
        timing(buildUs: 3000, rasterUs: 2000),
        timing(buildUs: 3000, rasterUs: 2000),
      ]);
      await FastTrackMcpJankMonitor.debugFlushWindow();

      expect(called, isFalse);
    });
  });

  group('FastTrackMcpMemoryMonitor', () {
    test('pressure reports when RSS over watermark', () async {
      Map<String, dynamic>? props;
      FastTrackMcpMemoryMonitor.debugOnReport = (_, p) async => props = p;

      FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(hours: 1),
        reportCoolDown: Duration.zero,
        pressureBytes: 100 * 1024 * 1024,
        rssReader: () => 150 * 1024 * 1024,
      );
      await FastTrackMcpMemoryMonitor.debugSampleRss(150 * 1024 * 1024);

      expect(props?['type'], 'memory_pressure');
      expect(props?['severity'], 'pressure');
      expect(props?['rss_bytes'], 150 * 1024 * 1024);
    });

    test('sustained growth reports leak_suspect', () async {
      Map<String, dynamic>? props;
      FastTrackMcpMemoryMonitor.debugOnReport = (_, p) async => props = p;

      const step = 3 * 1024 * 1024;
      FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(hours: 1),
        reportCoolDown: Duration.zero,
        growthStreak: 2,
        minGrowthBytes: step,
        pressureBytes: 0, // disable pressure path
      );

      var rss = 10 * 1024 * 1024;
      await FastTrackMcpMemoryMonitor.debugSampleRss(rss);
      rss += step;
      await FastTrackMcpMemoryMonitor.debugSampleRss(rss);
      rss += step;
      await FastTrackMcpMemoryMonitor.debugSampleRss(rss);

      expect(props?['type'], 'memory_growth');
      expect(props?['severity'], 'leak_suspect');
      expect(props?['growth_streak'], 2);
      expect((props?['growth_bytes'] as num), greaterThanOrEqualTo(step * 2));
    });

    test('flat RSS does not report growth', () async {
      var called = false;
      FastTrackMcpMemoryMonitor.debugOnReport = (_, __) async => called = true;

      FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(hours: 1),
        reportCoolDown: Duration.zero,
        growthStreak: 2,
        minGrowthBytes: 1024 * 1024,
        pressureBytes: 0,
      );

      await FastTrackMcpMemoryMonitor.debugSampleRss(20 * 1024 * 1024);
      await FastTrackMcpMemoryMonitor.debugSampleRss(20 * 1024 * 1024);
      await FastTrackMcpMemoryMonitor.debugSampleRss(20 * 1024 * 1024);

      expect(called, isFalse);
    });

    test('cooldown suppresses second report', () async {
      var count = 0;
      FastTrackMcpMemoryMonitor.debugOnReport = (_, __) async => count++;

      FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(hours: 1),
        reportCoolDown: const Duration(minutes: 5),
        pressureBytes: 50 * 1024 * 1024,
      );
      await FastTrackMcpMemoryMonitor.debugSampleRss(80 * 1024 * 1024);
      await FastTrackMcpMemoryMonitor.debugSampleRss(90 * 1024 * 1024);

      expect(count, 1);
    });
  });
}
