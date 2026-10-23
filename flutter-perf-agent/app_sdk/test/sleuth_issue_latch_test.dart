import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await SessionJournal.instance.stopAndWriteReport(writeReport: false);
  });

  test('appendRealtimeAlert replaces same memory alertType on step', () async {
    final j = SessionJournal.instance;
    j.start(sessionId: 'm1', testName: 'd0m');
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

    j.appendRealtimeAlert(
      AlertItem(
        type: 'heap_growing',
        stepId: '',
        action: 'sleuth:heap_growing',
        message: '内存压力：heap growing',
        value: {'stableId': 'heap_growing', 'severity': 'warning'},
        at: '2026-01-01T00:00:01.000Z',
      ),
    );
    j.appendRealtimeAlert(
      AlertItem(
        type: 'heap_growing',
        stepId: '',
        action: 'sleuth:heap_growing',
        message: '内存压力升级：heap growing (critical)',
        value: {'stableId': 'heap_growing', 'severity': 'critical'},
        at: '2026-01-01T00:00:02.000Z',
      ),
    );

    expect(j.steps.first.alerts, hasLength(1));
    expect(j.steps.first.alerts.first.type, 'heap_growing');
    final v = j.steps.first.alerts.first.value as Map;
    expect(v['severity'], 'critical');
  });

  test('default allowlist covers D0m + D0s families', () {
    expect(
      SleuthIssueLatch.memoryPressureIds,
      containsAll([
        'gc_pressure',
        'heap_growing',
        'heap_near_capacity',
        'native_memory_growing',
      ]),
    );
    expect(
      SleuthIssueLatch.runtimeIds,
      containsAll([
        'shader_compilation',
        'heavy_compute',
        'platform_channel_traffic',
        'stream_resource_growth',
        'rebuild_activity',
        'excessive_repaint',
      ]),
    );
    expect(
      SleuthIssueLatch.structuralIds,
      containsAll([
        'missing_repaint_boundary',
        'layout_bottleneck',
        'non_lazy_list',
        'setstate_scope',
      ]),
    );
    expect(SleuthIssueLatch.excludedIds, contains('jank_detected'));
    expect(
      SleuthIssueLatch.defaultAllowlist,
      containsAll(SleuthIssueLatch.runtimeIds),
    );
  });
}
