import 'dart:convert';
import 'dart:io';

import 'package:fast_track_mcp_server/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// Login → 我的 → Crash demo → three triggers → stop → assert crash kinds.
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
    stderr.writeln('FAIL: bridge ${health.msg}');
    exit(2);
  }
  stdout.writeln('bridge ok');

  await bridge.stopSession(writeReport: false);

  final session = PerfSession(
    sessionId: 'crash_demo_${DateTime.now().millisecondsSinceEpoch}',
    testName: 'crash_三连验收',
    startedAt: DateTime.now(),
    mode: health.data!.mode,
  );
  final started = await bridge.startSession(
    testName: session.testName,
    sessionId: session.sessionId,
    waitStableMs: config.waitStableMs,
    reportsDir: config.reportsDir,
  );
  if (!started.isOk) {
    stderr.writeln('FAIL start: ${started.msg}');
    exit(2);
  }
  stdout.writeln('session ${session.sessionId}');

  final ws = FlutterSkillVmClient.normalizeWsUri(health.data!.vmServiceUri!);
  var skill = FlutterSkillVmClient(ws, debugLog: true, maxRetries: 3);
  await skill.ensureConnected();

  var stepCounter = 0;
  final runner = ActionRunner(
    config: config,
    bridge: bridge,
    reports: reports,
    session: session,
    ensureSkillClient: () async {
      await skill.ensureConnected();
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
    stdout.writeln('[$label] ok=${r.ok} route=${r.route}');
  }

  // Ensure login page has password.
  await step(
    action: 'input_text',
    label: 'input:password',
    skillAction: (c) => c.enterText(text: '123456', target: 'password_field'),
  );
  await step(
    action: 'tap',
    label: 'tap:login',
    skillAction: (c) => c.tap(key: 'login_button', text: '登录'),
    expectNav: true,
    extraSettleMs: config.navigationWaitMs,
  );
  await step(
    action: 'tap',
    label: 'tap:mine',
    skillAction: (c) => c.tap(text: '我的'),
    extraSettleMs: 1200,
  );
  await step(
    action: 'tap',
    label: 'tap:open_crash_demo',
    skillAction: (c) => c.tap(key: 'open_crash_demo_button'),
    expectNav: true,
    extraSettleMs: 1000,
  );

  // Prefer visible titles: Key-only match is flaky when Semantics tree omits keys.
  for (final item in [
    ('crash_flutter_error_button', '1 · FlutterError'),
    ('crash_zone_button', '2 · Zone 未捕获'),
    ('crash_uncaught_button', '3 · PlatformDispatcher uncaught'),
  ]) {
    await step(
      action: 'tap',
      label: 'tap:${item.$1}',
      skillAction: (c) => c.tap(key: item.$1, text: item.$2),
      extraSettleMs: 900,
    );
  }

  await skill.disconnect();

  final stop = await bridge.stopSession(writeReport: true);
  stdout.writeln(
    'sdk stop code=${stop.code} html=${stop.data?.reportHtmlPath}',
  );

  // Prefer App SDK report under example_app/reports
  final exampleReports = Directory(p.join(repoRoot, 'example_app', 'reports'));
  File? sdkJson;
  if (await exampleReports.exists()) {
    final files = exampleReports
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.json') &&
              f.path.contains(session.sessionId) &&
              !p.basename(f.path).startsWith('live'),
        )
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (files.isNotEmpty) sdkJson = files.first;
  }

  if (sdkJson == null) {
    stderr.writeln('FAIL: no SDK json for ${session.sessionId}');
    exit(3);
  }

  // Rebuild HTML with latest protocol (expand/dedupe).
  final report =
      jsonDecode(await sdkJson.readAsString()) as Map<String, dynamic>;
  final htmlPath = sdkJson.path.replaceAll(RegExp(r'\.json$'), '.html');
  await File(htmlPath).writeAsString(buildHtmlReport(report));

  final alerts = (report['alerts'] as List?) ?? const [];
  final kinds = <String>{};
  for (final a in alerts) {
    if (a is! Map) continue;
    if (a['type']?.toString() != 'crash') continue;
    final v = a['value'];
    if (v is Map && v['kind'] != null) {
      kinds.add(v['kind'].toString());
    }
    stdout.writeln(
      'CRASH alert kind=${v is Map ? v['kind'] : '?'} '
      'msg=${a['message']}',
    );
  }

  stdout.writeln('SDK_REPORT=$htmlPath');
  stdout.writeln('crash_kinds=$kinds');

  const need = {'flutter_error', 'zone', 'uncaught'};
  final missing = need.difference(kinds);
  if (missing.isNotEmpty) {
    stderr.writeln('FAIL missing kinds: $missing');
    exit(4);
  }
  stdout.writeln('CRASH_DEMO_OK');
}
