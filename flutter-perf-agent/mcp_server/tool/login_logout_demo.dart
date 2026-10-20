import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// Login → 我的 → 退出登录 → write report (transition / leak demo).
Future<void> main() async {
  final repoRoot = p.normalize(p.join(Directory.current.path, '..'));
  final config = await PerfAgentConfig.load(
    p.join(repoRoot, 'perf_agent_config.json'),
    repoRoot: repoRoot,
  );
  final bridge = BridgeClient(config);
  final reports = ReportWriter(config);

  final health = await bridge.health();
  if (!health.isOk || health.data?.vmServiceUri == null) {
    stderr.writeln('FAIL: bridge unhealthy ${health.msg}');
    exit(2);
  }
  stdout.writeln('bridge ok vm=${health.data!.vmServiceUri}');

  await bridge.stopSession(writeReport: false);

  final session = PerfSession(
    sessionId: 'login_logout_${DateTime.now().millisecondsSinceEpoch}',
    testName: '登录退出',
    startedAt: DateTime.now(),
    mode: health.data!.mode,
  );

  final started = await bridge.startSession(
    testName: session.testName,
    sessionId: session.sessionId,
    waitStableMs: config.waitStableMs,
  );
  if (!started.isOk) {
    stderr.writeln('FAIL start: ${started.msg}');
    exit(2);
  }
  stdout.writeln('session ${session.sessionId}');

  final ws = FlutterSkillVmClient.normalizeWsUri(health.data!.vmServiceUri!);
  FlutterSkillClient? skill = FlutterSkillVmClient(
    ws,
    debugLog: true,
    maxRetries: 2,
  );
  await skill.ensureConnected();

  var stepCounter = 0;
  final runner = ActionRunner(
    config: config,
    bridge: bridge,
    reports: reports,
    session: session,
    ensureSkillClient: () async {
      await skill!.ensureConnected();
      return skill;
    },
    nextStepId: () => ++stepCounter,
  );

  Future<void> step({
    required String action,
    required String label,
    required SkillAction skillAction,
    bool expectNav = false,
    int extraSettleMs = 0,
  }) async {
    final r = await runner.run(
      action: action,
      actionLabel: label,
      skillAction: skillAction,
      expectNavigation: expectNav,
      extraSettleMs: extraSettleMs,
    );
    stdout.writeln(
      '[$label] ok=${r.ok} route=${r.route} alerts=${r.alerts.length} '
      'events=${r.events.length}',
    );
    for (final e in r.events) {
      if (e.type == 'navigate') {
        stdout.writeln(
          '  navigate ${e.detail['transitionKind']}: '
          '${e.detail['from']} → ${e.detail['to']}',
        );
        if (e.detail['leak'] != null) {
          stdout.writeln('  leak=${jsonEncode(e.detail['leak'])}');
        }
      }
    }
    for (final a in r.alerts) {
      stdout.writeln('  alert ${a.type}: ${a.message}');
    }
  }

  await step(
    action: 'input_text',
    label: 'input:password',
    skillAction: (c) => c.enterText(text: '123456', target: 'password_field'),
  );

  await step(
    action: 'tap',
    label: 'tap:login',
    skillAction: (c) => c.tap(text: '登录', key: 'login_button'),
    expectNav: true,
    extraSettleMs: config.navigationWaitMs,
  );

  // AppBar 右上角「我的」比 Tab 文案更稳（Tab 有时命中失败）
  await step(
    action: 'tap',
    label: 'tap:profile_button',
    skillAction: (c) => c.tap(key: 'profile_button', text: '我的'),
    expectNav: false,
    extraSettleMs: 600,
  );

  await step(
    action: 'tap',
    label: 'tap:logout',
    skillAction: (c) => c.tap(key: 'logout_button', text: '退出登录'),
    expectNav: true,
    extraSettleMs: 1800,
  );

  await skill.disconnect();
  skill = null;

  final paths = await reports.writeReports(session);
  try {
    final stop = await bridge.stopSession(writeReport: true);
    stdout.writeln(
      'sdk stop code=${stop.code} html=${stop.data?.reportHtmlPath}',
    );
  } catch (e) {
    stdout.writeln('sdk stop: $e');
  }

  stdout.writeln('MCP_REPORT_JSON=${paths.jsonPath}');
  stdout.writeln('MCP_REPORT_HTML=${paths.htmlPath}');
  stdout.writeln('steps=${session.steps.length} alerts=${session.alerts.length}');
  for (final a in session.alerts) {
    stdout.writeln('ALERT ${a.type}: ${a.message}');
  }
  stdout.writeln('LOGIN_LOGOUT_OK');
}
