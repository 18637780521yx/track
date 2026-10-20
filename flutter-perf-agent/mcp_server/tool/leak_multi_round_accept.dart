import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// 验收转场 V2 多轮泄漏：/profile push→pop×2 → multiRoundConfirmed。
Future<void> main() async {
  final repoRoot = p.normalize(p.join(Directory.current.path, '..'));
  final config = await PerfAgentConfig.load(
    p.join(repoRoot, 'perf_agent_config.json'),
    repoRoot: repoRoot,
  );
  final bridge = BridgeClient(config);

  final health = await bridge.health();
  if (!health.isOk || health.data?.vmServiceUri == null) {
    stderr.writeln('FAIL: bridge unhealthy ${health.msg}');
    exit(2);
  }
  stdout.writeln('route before: ${(await bridge.appRoute()).data?.route}');

  final ws = FlutterSkillVmClient.normalizeWsUri(health.data!.vmServiceUri!);
  final skill = FlutterSkillVmClient(ws, debugLog: true, maxRetries: 2);
  await skill.connect();

  Future<void> tapKey(String key, {String? text}) async {
    final r = await skill.tap(key: key, text: text);
    stdout.writeln('tap $key ok=${FlutterSkillVmClient.isOk(r)}');
    if (!FlutterSkillVmClient.isOk(r)) {
      stderr.writeln(const JsonEncoder.withIndent('  ').convert(r));
      throw StateError('tap failed: $key');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  Future<Map<String, dynamic>> probe(String route) async {
    final res = await bridge.transitionLeakProbe(route: route, settleMs: 1500);
    stdout.writeln(
      'probe /$route → ${const JsonEncoder.withIndent('  ').convert(res.toJson())}',
    );
    if (!res.isOk || res.data == null) {
      throw StateError('leak_probe failed: ${res.msg}');
    }
    return res.data!;
  }

  // Login if needed, then mine tab → push profile twice.
  final route0 = (await bridge.appRoute()).data?.route ?? '';
  if (route0.contains('login') || route0.isEmpty) {
    final enter = await skill.enterText(text: '123456', target: 'password_field');
    stdout.writeln('password ok=${FlutterSkillVmClient.isOk(enter)}');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tapKey('login_button', text: '登录');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    stdout.writeln('route after login: ${(await bridge.appRoute()).data?.route}');
  }

  await tapKey('tab_mine', text: '我的');
  stdout.writeln('route: ${(await bridge.appRoute()).data?.route}');

  // Round 1
  await tapKey('open_profile_push_button', text: '打开独立个人页');
  stdout.writeln('route: ${(await bridge.appRoute()).data?.route}');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final back1 = await skill.goBack();
  stdout.writeln('back1 ok=${FlutterSkillVmClient.isOk(back1)}');
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final p1 = await probe('/profile');

  // Round 2
  await tapKey('open_profile_push_button', text: '打开独立个人页');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final back2 = await skill.goBack();
  stdout.writeln('back2 ok=${FlutterSkillVmClient.isOk(back2)}');
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final p2 = await probe('/profile');

  await skill.disconnect();

  final multi = p2['multiRoundConfirmed'] == true;
  final counts = p2['aliveCounts'];
  final evidence = p2['evidence'];
  stdout.writeln('---');
  stdout.writeln('round1 aliveCount=${p1['aliveCount']} counts=${p1['aliveCounts']}');
  stdout.writeln('round2 aliveCount=${p2['aliveCount']} counts=$counts evidence=$evidence');
  stdout.writeln('multiRoundConfirmed=$multi');

  if (!multi) {
    stderr.writeln('FAIL: expected multiRoundConfirmed=true after 2 pops');
    exit(1);
  }
  if (evidence != 'weak_ref_multi') {
    stderr.writeln('FAIL: expected evidence=weak_ref_multi got $evidence');
    exit(1);
  }
  // ProfilePushController 无手写 track：登记来自 PerfDi.lazyPut（0.8.3）。
  stdout.writeln('PASS: Transition V2 multi-round leak confirmed (PerfDi auto-track)');
}
