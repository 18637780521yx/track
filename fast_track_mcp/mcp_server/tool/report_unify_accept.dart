import 'dart:convert';
import 'dart:io';

import 'package:fast_track_mcp_server/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// 验收：MCP ActionRunner 步骤 → mcp_server 报告。
Future<void> main() async {
  final repoRoot = p.normalize(p.join(Directory.current.path, '..'));
  final config = await FastTrackMcpConfig.load(
    p.join(repoRoot, 'perf_agent_config.json'),
    repoRoot: repoRoot,
  );
  final bridge = BridgeClient(config);
  final reports = ReportWriter(config);

  final health = await bridge.health();
  if (!health.isOk || health.data?.vmServiceUri == null) {
    stderr.writeln('FAIL: bridge unhealthy');
    exit(2);
  }

  await bridge.stopSession();

  final session = PerfSession(
    sessionId: 'unify_${DateTime.now().millisecondsSinceEpoch}',
    testName: 'report_unify_accept_cli',
    startedAt: DateTime.now(),
    mode: health.data!.mode,
  );
  final started = await bridge.startSession(
    testName: session.testName,
    sessionId: session.sessionId,
  );
  if (!started.isOk) {
    stderr.writeln('FAIL: start ${started.msg}');
    exit(2);
  }

  final ws = FlutterSkillVmClient.normalizeWsUri(health.data!.vmServiceUri!);
  final skill = FlutterSkillVmClient(ws, debugLog: true, maxRetries: 2);
  await skill.connect();

  var stepCounter = 0;
  final runner = ActionRunner(
    config: config,
    bridge: bridge,
    reports: reports,
    session: session,
    ensureSkillClient: () async => skill,
    nextStepId: () => ++stepCounter,
  );

  Future<void> act(
    String label,
    Future<Map<String, dynamic>> Function(FlutterSkillClient c) fn, {
    int wait = 800,
  }) async {
    stdout.writeln('>> $label');
    final step = await runner.run(
      action: label.split(':').first,
      actionLabel: label,
      waitStableMs: wait,
      skillAction: fn,
    );
    stdout.writeln(
      '   route=${step.route} events=${step.events.length} ok=${step.ok}',
    );
  }

  // Login if needed.
  final route0 = (await bridge.appRoute()).data?.route ?? '';
  if (route0.contains('login') || route0.isEmpty) {
    await act(
      'input_text:password_field',
      (c) => c.enterText(text: '123456', target: 'password_field'),
      wait: 400,
    );
    await act(
      'tap:login_button',
      (c) => c.tap(key: 'login_button', text: '登录'),
      wait: 1800,
    );
  }

  await act('tap:tab_mine', (c) => c.tap(key: 'tab_mine', text: '我的'));
  await act(
    'tap:open_profile_push_button',
    (c) => c.tap(key: 'open_profile_push_button'),
    wait: 1200,
  );
  await act('skill_call:goBack', (c) => c.goBack(), wait: 2200);
  await act(
    'tap:open_profile_push_button',
    (c) => c.tap(key: 'open_profile_push_button'),
    wait: 1200,
  );
  await act('skill_call:goBack', (c) => c.goBack(), wait: 2500);

  await skill.disconnect();

  await bridge.stopSession();
  final paths = await reports.writeReports(session);
  stdout.writeln('json=${paths.jsonPath}');
  stdout.writeln('html=${paths.htmlPath}');

  final report = jsonDecode(await File(paths.jsonPath).readAsString())
      as Map<String, dynamic>;
  final owner = report['reportOwner'];
  final steps = (report['steps'] as List?) ?? const [];
  final ev = steps.fold<int>(
    0,
    (n, s) => n + (((s as Map)['events'] as List?)?.length ?? 0),
  );
  final tl = ((report['view'] as Map?)?['timeline'] as List?) ?? const [];
  final mods = <String, int>{};
  for (final t in tl) {
    if (t is! Map) continue;
    final m = t['module']?.toString() ?? '?';
    mods[m] = (mods[m] ?? 0) + 1;
  }
  final multi = ((report['alerts'] as List?) ?? const []).where((a) {
    if (a is! Map) return false;
    if (a['type'] != 'memory_leak' && a['type'] != 'transition_memory_leak') {
      return false;
    }
    final v = a['value'];
    return v is Map && v['multiRoundConfirmed'] == true;
  }).length;

  stdout.writeln(
    'owner=$owner steps=${steps.length} events=$ev timeline=${tl.length} '
    'mods=$mods multi=$multi',
  );

  final html = await File(paths.htmlPath).readAsString();
  final ok = ev >= 8 &&
      mods.containsKey('transition') &&
      multi >= 1 &&
      html.contains('多轮确认');

  stdout.writeln(const JsonEncoder.withIndent('  ').convert({
    'owner': owner,
    'events': ev,
    'mods': mods,
    'multi': multi,
    'htmlPath': paths.htmlPath,
  }));

  if (!ok) {
    stderr.writeln('FAIL: report unify checks');
    exit(1);
  }
  stdout.writeln('PASS: MCP report unify');
}
