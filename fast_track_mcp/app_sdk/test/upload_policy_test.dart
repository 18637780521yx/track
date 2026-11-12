import 'dart:ui';

import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:fast_track_mcp/src/detect/detect_sink.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final records = <String>[];
  var flushes = 0;
  FlutterExceptionHandler? originalErrorHandler;

  setUp(() {
    records.clear();
    flushes = 0;
    originalErrorHandler = FlutterError.onError;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FastTrackMcpDetectSink.debugOnTrack = (name, _) async => records.add(name);
    FastTrackMcpDetectSink.debugOnFlush = () async => flushes++;
  });

  tearDown(() async {
    ManualGestureRecorder.instance.stop();
    await FastTrackMcpJankMonitor.debugReset();
    await FastTrackMcpMemoryMonitor.debugReset();
    await FastTrackMcpAnrWatchdog.debugReset();
    await FastTrackMcpCrashHandler.debugReset();
    AppLifecycleTracker.instance.stop();
    TransitionLedger.instance.reset();
    FastTrackMcpDetectSink.debugOnTrack = null;
    FastTrackMcpDetectSink.debugOnFlush = null;
    FlutterError.onError = originalErrorHandler;
    debugDefaultTargetPlatformOverride = null;
  });

  test('page navigation queues both events without forcing an upload',
      () async {
    TransitionLedger.instance.onPush('/upload-policy');
    TransitionLedger.instance.onPop('/upload-policy');
    await Future<void>.delayed(Duration.zero);
    expect(records.where((name) => name == 'app_transition'), hasLength(2));
    expect(records, contains('app_page'));
    expect(flushes, 0);
  });

  testWidgets('manual clicks and scrolls queue without immediate upload',
      (tester) async {
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: Text('Target')))));
    ManualGestureRecorder.instance.ensureStarted();
    await tester.tapAt(const Offset(200, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveTo(const Offset(200, 80));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(records, containsAll(['ui_tap', 'ui_scroll']));
    expect(flushes, 0);
    ManualGestureRecorder.instance.stop();
  });

  test('frozen frames and memory pressure join the regular queue', () async {
    FastTrackMcpJankMonitor.start(fpsTarget: 60, reportInterval: Duration.zero);
    FastTrackMcpJankMonitor.debugHandleTimings([
      FrameTiming(
        vsyncStart: 0,
        buildStart: 0,
        buildFinish: 700000,
        rasterStart: 700000,
        rasterFinish: 800000,
        rasterFinishWallTime: 800000,
      )
    ]);
    await FastTrackMcpJankMonitor.debugFlushWindow();
    FastTrackMcpMemoryMonitor.start(
        sampleInterval: const Duration(hours: 1),
        pressureBytes: 100,
        enableVmMonitoring: false);
    for (var i = 0; i < 5; i++) {
      await FastTrackMcpMemoryMonitor.debugSampleRss(200, atMs: i * 3600000);
    }
    expect(records, containsAll(['app_jank', 'app_memory_leak']));
    expect(flushes, 0);
  });

  test('background flushes once for hidden/paused, foreground waits', () async {
    final lifecycle = AppLifecycleTracker.instance;
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(flushes, 0);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(flushes, 1);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(flushes, 1);
  });

  test('Flutter errors and ANRs keep immediate upload behavior', () async {
    FlutterError.onError = (_) {};
    FastTrackMcpCrashHandler.install();
    FlutterError.reportError(FlutterErrorDetails(
        exception: StateError('upload now'), stack: StackTrace.current));
    await Future<void>.delayed(Duration.zero);
    expect(records, contains('app_error'));
    expect(flushes, 1);
    await FastTrackMcpAnrWatchdog.debugEmit({'blocked_ms': 5000});
    expect(records, contains('app_anr'));
    expect(flushes, 2);
  });
}
