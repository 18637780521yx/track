import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// Verify cold_start + route steps: login → home → mine → logout.
Future<void> main() async {
  final repoRoot = p.normalize(p.join(Directory.current.path, '..'));
  final config = await PerfAgentConfig.load(
    p.join(repoRoot, 'perf_agent_config.json'),
    repoRoot: repoRoot,
  );
  final bridge = BridgeClient(config);
  final reports = ReportWriter(config);

  final health0 = await bridge.health();
  if (!health0.isOk) {
    stderr.writeln('FAIL: bridge unhealthy ${health0.msg}');
    exit(2);
  }

  await bridge.stopSession();
  final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
  final started = await bridge.startSession(
    testName: 'route_steps_smoke',
    sessionId: sessionId,
  );
  if (!started.isOk) {
    stderr.writeln('FAIL start: ${started.msg}');
    exit(2);
  }

  final session = PerfSession(
    sessionId: sessionId,
    testName: 'route_steps_smoke',
    startedAt: DateTime.now(),
    mode: health0.data?.mode,
  );

  var stepCounter = 0;
  FlutterSkillClient? skill;
  String? wsUri = health0.data?.vmServiceUri;

  Future<FlutterSkillClient?> ensureSkill() async {
    final health = await bridge.health();
    final raw = health.data?.vmServiceUri;
    if (raw != null && raw.isNotEmpty) {
      wsUri = raw;
    }
    if (wsUri == null) return null;
    final ws = FlutterSkillVmClient.normalizeWsUri(wsUri!);
    if (skill == null || skill!.wsUri != ws) {
      await skill?.disconnect();
      skill = FlutterSkillVmClient(ws, debugLog: true, maxRetries: 2);
    }
    await skill!.ensureConnected();
    return skill;
  }

  final runner = ActionRunner(
    config: config,
    bridge: bridge,
    reports: reports,
    session: session,
    ensureSkillClient: ensureSkill,
    nextStepId: () => ++stepCounter,
  );

  // True cold start: kill + relaunch .app, then record TTFF step.
  await runner.recordColdStart(
    relaunch: true,
    onAfterRelaunch: () async {
      await skill?.disconnect();
      skill = null;
      wsUri = null;
      await bridge.ensureResolved(force: true);
    },
  );
  await reports.writeLiveReports(session);

  await runner.run(
    action: 'input_text',
    actionLabel: 'input_text:password_field',
    extraStepFields: {'targetDesc': 'password_field', 'text': '123456'},
    skillAction: (c) => c.enterText(text: '123456', target: 'password_field'),
  );
  await reports.writeLiveReports(session);

  await runner.run(
    action: 'tap',
    actionLabel: 'tap:login_button',
    expectNavigation: true,
    extraSettleMs: config.navigationWaitMs,
    extraStepFields: {'targetDesc': 'login_button'},
    skillAction: (c) => c.tap(text: '登录', key: 'login_button'),
  );
  await reports.writeLiveReports(session);

  await Future<void>.delayed(const Duration(milliseconds: 800));

  await runner.run(
    action: 'tap',
    actionLabel: 'tap:profile_button',
    expectNavigation: true,
    extraSettleMs: config.navigationWaitMs,
    extraStepFields: {'targetDesc': 'profile_button'},
    skillAction: (c) => c.tap(key: 'profile_button'),
  );
  await reports.writeLiveReports(session);

  await runner.run(
    action: 'tap',
    actionLabel: 'tap:logout_button',
    expectNavigation: true,
    extraSettleMs: config.navigationWaitMs,
    extraStepFields: {'targetDesc': 'logout_button'},
    skillAction: (c) => c.tap(text: '退出登录', key: 'logout_button'),
  );

  final paths = await reports.writeReports(session);
  await skill?.disconnect();
  await bridge.stopSession();

  stdout.writeln('html=${paths.htmlPath}');
  stdout.writeln('steps=${session.steps.length}');
  for (final s in session.steps) {
    final types = s.events.map((e) => e.type).join('→');
    stdout.writeln(
      '  ${s.stepId} action=${s.action} route=${s.route} ok=${s.ok} '
      'events=$types net=${s.networkRequests.length} '
      'ttff=${s.extra['ttffMs']} launch=${s.extra['processLaunchMs']}',
    );
  }

  final cold = session.steps.where((s) => s.action == 'cold_start').toList();
  final loginChapters = session.steps
      .where((s) => s.route == '/login' && s.action != 'cold_start')
      .toList();
  final routes = session.steps.map((s) => s.route).toList();
  final hasHome = routes.any((r) => r != null && r.contains('/home#home'));
  final hasMine = routes.any((r) => r != null && r.contains('/home#mine'));
  final login = loginChapters.isNotEmpty ? loginChapters.first : null;
  final loginTypes = login?.events.map((e) => e.type).toList() ?? const [];
  final hasLinearLogin = login != null &&
      loginTypes.contains('screenshot') &&
      loginTypes.contains('action') &&
      loginTypes.contains('network') &&
      loginTypes.contains('navigate');
  if (cold.isEmpty || !hasHome || !hasLinearLogin) {
    stderr.writeln(
      'FAIL: expected cold_start + linear /login events + /home#home; '
      'routes=$routes loginEvents=$loginTypes',
    );
    exit(1);
  }
  stdout.writeln(
    jsonEncode({
      'ok': true,
      'coldStart': true,
      'ttffMs': cold.first.extra['ttffMs'],
      'processLaunchMs': cold.first.extra['processLaunchMs'],
      'loginEvents': loginTypes,
      'hasHome': hasHome,
      'hasMine': hasMine,
      'routes': routes,
      'html': paths.htmlPath,
    }),
  );
}
