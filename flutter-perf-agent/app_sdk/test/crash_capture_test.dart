import 'package:flutter_perf_agent/flutter_perf_agent.dart';
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
}
