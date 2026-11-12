import 'dart:developer' show Timeline;
import 'dart:ui';
import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clock = ColdStartClock.instance;
  tearDown(clock.debugReset);

  test('first frame records actual phases and raster-finish TTFF once', () {
    clock.start();
    final at = Timeline.now;
    clock.debugHandleTimings([
      FrameTiming(
          vsyncStart: at,
          buildStart: at + 1000,
          buildFinish: at + 4000,
          rasterStart: at + 6000,
          rasterFinish: at + 10000,
          rasterFinishWallTime: at + 10000)
    ]);
    final metrics = clock.metrics();
    expect(metrics['firstFrameBuildMs'], 3);
    expect(metrics['firstFrameRasterMs'], 4);
    expect(metrics['firstFrameTotalMs'], 10);
    expect(metrics['ttffMs'], greaterThanOrEqualTo(10));
    expect(metrics['ttiMs'], isNull);
    expect(metrics['ttffSource'], 'frame_timing_monotonic');
    clock.debugHandleTimings([]);
    expect(clock.metrics()['ttffMs'], metrics['ttffMs']);
  });

  test('TTI timeout leaves readiness unknown and reset creates new waiters',
      () async {
    clock.markDartEntry();
    clock.markFirstFrame();
    await clock.waitInteractive(timeout: Duration.zero);
    expect(clock.hasInteractive, false);
    expect(clock.metrics()['ttiSource'], 'unknown');
    clock.markInteractive();
    expect(clock.metrics()['ttiSource'], 'explicit');
    clock.debugReset();
    await clock.waitInteractive(timeout: Duration.zero);
    expect(clock.hasInteractive, false);
  });
}
