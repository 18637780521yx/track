import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// End-to-end smoke: Bridge + flutter_skill + Sleuth/RSS reports.
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

  await bridge.stopSession();

  final rawVm = health['vmServiceUri'] as String?;
  if (rawVm == null || rawVm.isEmpty) {
    stderr.writeln('FAIL: no vmServiceUri in health');
    exit(2);
  }
  final wsUri = FlutterSkillVmClient.normalizeWsUri(rawVm);
  stdout.writeln('vm=$wsUri (UI only)');

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
    waitStableMs: 0,
  );
  stdout.writeln(
    'session ok=${started['ok']} id=${started['sessionId']} '
    'err=${started['error']}',
  );
  if (started['ok'] != true) {
    stderr.writeln('FAIL: start session');
    stderr.writeln(const JsonEncoder.withIndent('  ').convert(started));
    exit(2);
  }

  final skill = FlutterSkillVmClient(
    wsUri,
    maxRetries: config.maxRetries,
    retryDelayMs: config.retryDelayMs,
    debugLog: true,
  );
  await skill.connect();

  var step = 0;
  Future<Map<String, dynamic>> runStep({
    required String action,
    required String label,
    required Future<Map<String, dynamic>> Function(FlutterSkillVmClient c)
        doAction,
    Map<String, dynamic>? extra,
    int extraSettleMs = 0,
  }) async {
    step += 1;
    final stepId = 'step_$step';
    final t0 = DateTime.now();
    final beforeRes = await bridge.snapshot();
    final before =
        (beforeRes['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};

    Map<String, dynamic> actionResult;
    try {
      await skill.ensureConnected();
      actionResult = await doAction(skill);
    } catch (e) {
      actionResult = {'success': false, 'error': e.toString()};
    }

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
      final settle = config.postActionSettleMs + extraSettleMs;
      if (settle > 0) {
        await Future<void>.delayed(Duration(milliseconds: settle));
      }
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

    String? screenshotPath;
    String? screenshotDataUri;
    if (config.captureScreenshots) {
      try {
        final b64 = await skill.screenshotBase64();
        if (b64 != null) {
          final dir = Directory(
            p.join(config.reportsDir, 'screenshots', session.sessionId),
          );
          await dir.create(recursive: true);
          screenshotPath = p.join(dir.path, '$stepId.png');
          await File(screenshotPath).writeAsBytes(base64Decode(b64));
          screenshotDataUri = 'data:image/png;base64,$b64';
        }
      } catch (e) {
        stdout.writeln('screenshot skipped: $e');
      }
    }

    final record = {
      'stepId': stepId,
      'action': action,
      'ok': ok,
      'driver': actionResult.containsKey('legacy')
          ? 'legacy_fallback'
          : 'flutter_skill',
      'metricsSource': 'sleuth_bridge',
      'actionResult': actionResult,
      'diff': diff,
      'alerts': alerts,
      if (screenshotPath != null) 'screenshotPath': screenshotPath,
      if (screenshotDataUri != null) 'screenshotDataUri': screenshotDataUri,
      'at': DateTime.now().toIso8601String(),
      ...?extra,
    };
    session.addStep(record);
    stdout.writeln(
      '[$stepId] $action ok=$ok memΔ=${diff['memoryDeltaMb']} '
      'jankΔ=${diff['jankDelta']} alerts=${alerts.length} '
      'shot=${screenshotPath != null}',
    );
    return record;
  }

  await runStep(
    action: 'input_text',
    label: 'password_field',
    extra: {'targetDesc': 'password_field', 'textPreview': '12***'},
    doAction: (c) => c.enterText(text: '123456', target: 'password_field'),
  );

  await runStep(
    action: 'tap',
    label: '登录',
    extra: {'targetDesc': '登录'},
    extraSettleMs: config.navigationWaitMs,
    doAction: (c) => c.tap(text: '登录', key: 'login_button'),
  );

  await runStep(
    action: 'scroll',
    label: 'down',
    extra: {'direction': 'down', 'distance': 400},
    doAction: (c) => c.swipe(direction: 'down', distance: 400),
  );

  await runStep(
    action: 'scroll',
    label: 'down',
    extra: {'direction': 'down', 'distance': 400},
    doAction: (c) => c.swipe(direction: 'down', distance: 400),
  );

  await skill.disconnect();
  await bridge.stopSession();
  final paths = await reports.writeReports(session);

  stdout.writeln('== done ==');
  stdout.writeln('json: ${paths.jsonPath}');
  stdout.writeln('html: ${paths.htmlPath}');
  stdout.writeln('steps=${session.steps.length} alerts=${session.alerts.length}');

  final okCount = session.steps.where((s) => s['ok'] == true).length;
  if (okCount < 4) {
    stderr.writeln('FAIL: expected 4 ok steps, got $okCount');
    exit(1);
  }
  stdout.writeln('SMOKE_OK');
}
