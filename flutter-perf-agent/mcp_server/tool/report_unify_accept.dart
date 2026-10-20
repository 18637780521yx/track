import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// 验收：MCP ActionRunner 全量镜像 → 仅 App SDK 报告（与手动同款）。
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
    stderr.writeln('FAIL: bridge unhealthy');
    exit(2);
  }

  await bridge.stopSession(writeReport: false);

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

  // Same as fixed stop_perf_test: SDK only.
  final stop = await bridge.stopSession(writeReport: true);
  final sdkJson = stop.data?.reportJsonPath;
  final sdkHtml = stop.data?.reportHtmlPath;
  stdout.writeln('sdkJson=$sdkJson');
  stdout.writeln('sdkHtml=$sdkHtml');

  if (sdkJson == null || sdkHtml == null) {
    stderr.writeln('FAIL: no SDK report paths');
    exit(1);
  }

  // Ensure no twin mcp fat report for this session within 2s window.
  final reportsDir = Directory(config.reportsDir);
  final sid = session.sessionId;
  final twins = reportsDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains(sid) && f.path.endsWith('.html'))
      .map((f) => f.path)
      .toList();
  stdout.writeln('html files for session: $twins');

  final report =
      jsonDecode(await File(sdkJson).readAsString()) as Map<String, dynamic>;
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
    if (a['type'] != 'transition_memory_leak') return false;
    final v = a['value'];
    return v is Map && v['multiRoundConfirmed'] == true;
  }).length;

  stdout.writeln(
    'owner=$owner steps=${steps.length} events=$ev timeline=${tl.length} '
    'mods=$mods multi=$multi',
  );

  final html = await File(sdkHtml).readAsString();
  final ok = owner == 'app_sdk' &&
      ev >= 8 &&
      mods.containsKey('transition') &&
      multi >= 1 &&
      html.contains('多轮确认') &&
      twins.length == 1; // only live+final? final one named stamp_... ; live separate
  // twins may include live_ — allow live + one final
  final finals = twins.where((p) => !p.contains('live_')).toList();
  final ok2 = owner == 'app_sdk' &&
      ev >= 8 &&
      mods.containsKey('transition') &&
      multi >= 1 &&
      html.contains('多轮确认') &&
      finals.length == 1;

  stdout.writeln(const JsonEncoder.withIndent('  ').convert({
    'owner': owner,
    'events': ev,
    'mods': mods,
    'multi': multi,
    'finalHtmlCount': finals.length,
    'htmlPath': sdkHtml,
  }));

  if (!ok2) {
    stderr.writeln('FAIL: report unify checks');
    exit(1);
  }
  stdout.writeln('PASS: MCP→SDK unified report');
}
