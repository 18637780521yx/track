import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    CrashCapture.instance.stop();
    await SessionJournal.instance.stopAndWriteReport(writeReport: false);
  });

  test('report writes crash alert while session active', () async {
    final j = SessionJournal.instance;
    j.start(sessionId: 'c1', testName: 'crash');
    j.addStep(
      StepResult(
        stepId: 'step_1',
        action: 'route:/home',
        route: '/home',
        ok: true,
        driver: 'app_sdk',
        at: '2026-01-01T00:00:00.000Z',
      ),
    );

    CrashCapture.instance.report(
      StateError('boom for D1'),
      StackTrace.current,
      kind: 'zone',
      fatal: true,
    );

    expect(j.alerts, isNotEmpty);
    final a = j.alerts.last;
    expect(a.type, 'crash');
    expect(a.message, contains('boom for D1'));
    final v = a.value as Map;
    expect(v['kind'], 'zone');
    expect(v['fatal'], isTrue);
    expect(v['stack'], isNotEmpty);
  });

  test('report is no-op without active session', () {
    CrashCapture.instance.report(
      Exception('orphan'),
      StackTrace.current,
      kind: 'zone',
    );
    expect(SessionJournal.instance.alerts, isEmpty);
  });

  test('dedupes identical errors within window', () async {
    final j = SessionJournal.instance;
    j.start(sessionId: 'c2', testName: 'dedupe');
    j.addStep(
      StepResult(
        stepId: 'step_1',
        action: 'route:/a',
        route: '/a',
        ok: true,
        driver: 'mcp',
        at: '2026-01-01T00:00:00.000Z',
      ),
    );

    final st = StackTrace.current;
    CrashCapture.instance.report(Exception('same'), st, kind: 'flutter_error');
    CrashCapture.instance.report(Exception('same'), st, kind: 'flutter_error');
    expect(j.alerts.where((a) => a.type == 'crash'), hasLength(1));
  });

  test('three crash kinds coexist; MCP upsert keeps them', () async {
    final j = SessionJournal.instance;
    j.start(sessionId: 'c3', testName: 'kinds');
    j.addStep(
      StepResult(
        stepId: 'step_1',
        action: 'route:/demo/crash_capture',
        route: '/demo/crash_capture',
        ok: true,
        driver: 'mcp',
        at: '2026-01-01T00:00:00.000Z',
        extra: const {'source': 'mcp'},
      ),
    );

    CrashCapture.instance.report(Exception('fe'), StackTrace.current,
        kind: 'flutter_error');
    CrashCapture.instance.report(Exception('zn'), StackTrace.current,
        kind: 'zone', fatal: true);
    CrashCapture.instance.report(Exception('uc'), StackTrace.current,
        kind: 'uncaught', fatal: true);

    expect(
      j.alerts.where((a) => a.type == 'crash').map((a) =>
          (a.value as Map)['kind']).toSet(),
      {'flutter_error', 'zone', 'uncaught'},
    );

    // MCP chapter upsert without crash alerts must not wipe them.
    j.upsertStep(
      StepResult(
        stepId: 'step_1',
        action: 'route:/demo/crash_capture',
        route: '/demo/crash_capture',
        ok: true,
        driver: 'mcp',
        at: '2026-01-01T00:00:01.000Z',
        alerts: [
          AlertItem(
            // memory_increase 会被 _stripLegacyDetectorAlerts 丢掉；用自定义类型验证合并。
            type: 'custom_probe',
            stepId: 'step_1',
            action: 'tap',
            message: 'probe',
            value: 9.0,
          ),
        ],
        extra: const {'source': 'mcp'},
      ),
    );

    final kinds = j.alerts
        .where((a) => a.type == 'crash')
        .map((a) => (a.value as Map)['kind'])
        .toSet();
    expect(kinds, {'flutter_error', 'zone', 'uncaught'});
    expect(j.alerts.any((a) => a.type == 'custom_probe'), isTrue);
  });
}
