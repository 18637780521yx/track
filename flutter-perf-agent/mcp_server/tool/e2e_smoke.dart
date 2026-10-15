import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// End-to-end smoke without Cursor: Bridge + flutter_skill + report writer.
Future<void> main(List<String> args) async {
  final repoRoot = p.normalize(p.join(Directory.current.path, '..'));
  final configPath = p.join(repoRoot, 'perf_agent_config.json');
  final config = await PerfAgentConfig.load(configPath, repoRoot: repoRoot);
  final bridge = BridgeClient(config);
  final reports = ReportWriter(config);

  stdout.writeln('== health ==');
  final health = await bridge.health();
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(health));
  if (health['ok'] != true) {
    stderr.writeln('FAIL: bridge not healthy');
    exit(2);
  }

  final rawVm = health['vmServiceUri'] as String?;
  if (rawVm == null || rawVm.isEmpty) {
    stderr.writeln('FAIL: no vmServiceUri in health');
    exit(2);
  }
  final wsUri = FlutterSkillVmClient.normalizeWsUri(rawVm);
  stdout.writeln('vm=$wsUri');

  final session = PerfSession(
    sessionId: 'smoke_${DateTime.now().millisecondsSinceEpoch}',
    testName: 'e2e_login_scroll_smoke',
    startedAt: DateTime.now(),
    mode: health['mode'] as String?,
  );

  stdout.writeln('== start session ==');
  final started = await bridge.startSession(
    testName: session.testName,
    sessionId: session.sessionId,
  );
  stdout.writeln('session ok=${started['ok']} id=${started['sessionId']}');

  var step = 0;
  Future<Map<String, dynamic>> runStep({
    required String action,
    required String label,
    required Future<Map<String, dynamic>> Function(FlutterSkillVmClient c)
        skill,
    Map<String, dynamic>? extra,
  }) async {
    step += 1;
    final stepId = 'step_$step';
    final t0 = DateTime.now();
    final beforeRes = await bridge.snapshot();
    final before =
        (beforeRes['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};

    final client = FlutterSkillVmClient(
      wsUri,
      maxRetries: config.maxRetries,
      retryDelayMs: config.retryDelayMs,
      debugLog: true,
    );
    Map<String, dynamic> actionResult;
    try {
      await client.connect();
      actionResult = await skill(client);
    } catch (e) {
      actionResult = {'success': false, 'error': e.toString()};
    } finally {
      await client.disconnect();
    }

    // Legacy fallback for tap only.
    if (!FlutterSkillVmClient.isOk(actionResult) && action == 'tap') {
      stdout.writeln('tap flutter_skill failed, trying legacy…');
      final legacy = await bridge.tapLegacy(targetDesc: label);
      actionResult = {
        'success': legacy['ok'] == true,
        'flutterSkill': actionResult,
        'legacy': legacy['action'],
      };
    } else if (FlutterSkillVmClient.isOk(actionResult)) {
      await bridge.waitStable(waitStableMs: config.waitStableMs);
    }

    final afterRes = await bridge.snapshot();
    final after =
        (afterRes['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};
    final diff = computePerfDiff(
      before: before,
      after: after,
      durationMs: DateTime.now().difference(t0).inMilliseconds,
    );
    final ok = FlutterSkillVmClient.isOk(actionResult);
    final alerts = reports.evaluateDiff(
      diff,
      stepId: stepId,
      action: '$action:$label',
    );
    for (final a in alerts) {
      session.addAlert(a);
    }
    final record = {
      'stepId': stepId,
      'action': action,
      'ok': ok,
      'driver': actionResult.containsKey('legacy')
          ? 'legacy_fallback'
          : 'flutter_skill',
      'actionResult': actionResult,
      'diff': diff,
      'alerts': alerts,
      'at': DateTime.now().toIso8601String(),
      ...?extra,
    };
    session.addStep(record);
    stdout.writeln(
      '[$stepId] $action ok=$ok memΔ=${diff['memoryDeltaMb']} '
      'jankΔ=${diff['jankDelta']} alerts=${alerts.length}',
    );
    return record;
  }

  // Flow: password → login → scroll down x2
  await runStep(
    action: 'input_text',
    label: 'password_field',
    extra: {'targetDesc': 'password_field', 'textPreview': '12***'},
    skill: (c) => c.enterText(text: '123456', target: 'password_field'),
  );

  await runStep(
    action: 'tap',
    label: '登录',
    extra: {'targetDesc': '登录'},
    skill: (c) => c.tap(text: '登录', key: 'login_button'),
  );

  await runStep(
    action: 'scroll',
    label: 'down',
    extra: {'direction': 'down', 'distance': 400},
    skill: (c) => c.swipe(direction: 'down', distance: 400),
  );

  await runStep(
    action: 'scroll',
    label: 'down',
    extra: {'direction': 'down', 'distance': 400},
    skill: (c) => c.swipe(direction: 'down', distance: 400),
  );

  await bridge.stopSession();
  final paths = await reports.writeReports(session);

  stdout.writeln('== done ==');
  stdout.writeln('json: ${paths.jsonPath}');
  stdout.writeln('html: ${paths.htmlPath}');
  stdout.writeln('steps=${session.steps.length} alerts=${session.alerts.length}');
  stdout.writeln(
    'okSteps=${session.steps.where((s) => s['ok'] == true).length}',
  );

  final okCount = session.steps.where((s) => s['ok'] == true).length;
  // Pass if at least login path partially worked (input or tap).
  if (okCount == 0) {
    stderr.writeln('FAIL: all steps failed');
    exit(1);
  }
  stdout.writeln('SMOKE_OK');
}
