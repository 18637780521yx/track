import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await SessionJournal.instance.stopAndWriteReport(writeReport: false);
  });

  test('appendRealtimeAlert attaches to latest non-lifecycle step', () async {
    final j = SessionJournal.instance;
    j.start(sessionId: 't1', testName: 'latch');
    j.addStep(
      StepResult(
        stepId: 'step_1',
        action: 'lifecycle:cold_start',
        ok: true,
        driver: 'app_sdk',
        at: '2026-01-01T00:00:00.000Z',
      ),
    );
    j.addStep(
      StepResult(
        stepId: 'step_2',
        action: 'route:/home',
        route: '/home',
        ok: true,
        driver: 'app_sdk',
        at: '2026-01-01T00:00:01.000Z',
      ),
    );

    j.appendRealtimeAlert(
      AlertItem(
        type: 'jank',
        stepId: '',
        action: 'frame_jank',
        message: '卡顿 32ms · 疑似build',
        value: {
          'frameNumber': 42,
          'frameMs': 32.0,
          'suspectedPhase': 'build',
          'reason': 'build dominated',
          'vmMode': 'full',
        },
        at: '2026-01-01T00:00:01.500Z',
      ),
      routeHint: '/home',
    );

    expect(j.steps.length, 2);
    expect(j.steps[1].alerts, hasLength(1));
    expect(j.steps[1].alerts.first.type, 'jank');
    expect(j.steps[1].alerts.first.stepId, 'step_2');
    expect(j.steps[1].alerts.first.at, '2026-01-01T00:00:01.500Z');
    expect(j.alerts, hasLength(1));
  });

  test('upgradeRealtimeFrameAlert replaces value by frameNumber', () async {
    final j = SessionJournal.instance;
    j.start(sessionId: 't2', testName: 'upgrade');
    j.addStep(
      StepResult(
        stepId: 'step_1',
        action: 'route:/a',
        route: '/a',
        ok: true,
        driver: 'mcp',
        at: '2026-01-01T00:00:00.000Z',
        alerts: [
          AlertItem(
            type: 'jank',
            stepId: 'step_1',
            action: 'frame_jank',
            message: '卡顿',
            value: {'frameNumber': 7, 'frameMs': 40.0, 'vmMode': 'basic'},
            at: '2026-01-01T00:00:00.100Z',
          ),
        ],
      ),
    );
    j.upgradeRealtimeFrameAlert(
      frameNumber: 7,
      value: {
        'frameNumber': 7,
        'frameMs': 40.0,
        'vmMode': 'correlated',
        'topFunctions': [
          {'name': 'HeavyWidget.build'},
        ],
      },
    );
    final v = j.steps.first.alerts.first.value as Map;
    expect(v['vmMode'], 'correlated');
    expect(v['topFunctions'], isNotEmpty);
  });
}
