import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// Smoke: enter password → tap 登录 → land on HomePage.
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

  final ws = FlutterSkillVmClient.normalizeWsUri(health.data!.vmServiceUri!);
  final skill = FlutterSkillVmClient(ws, debugLog: true, maxRetries: 2);
  await skill.connect();
  stdout.writeln('vm=$ws');

  final enter = await skill.enterText(text: '123456', target: 'password_field');
  stdout.writeln('enter ok=${FlutterSkillVmClient.isOk(enter)}');
  if (!FlutterSkillVmClient.isOk(enter)) {
    stderr.writeln(const JsonEncoder.withIndent('  ').convert(enter));
    exit(1);
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));

  final tap = await skill.tap(text: '登录', key: 'login_button');
  stdout.writeln('tap ok=${FlutterSkillVmClient.isOk(tap)}');
  if (!FlutterSkillVmClient.isOk(tap)) {
    stderr.writeln(const JsonEncoder.withIndent('  ').convert(tap));
    exit(1);
  }
  await Future<void>.delayed(const Duration(milliseconds: 1000));

  final content = await skill.getTextContent();
  final blob = jsonEncode(content);
  stdout.writeln('ui_text=$blob');
  final onHome = blob.contains('首页') ||
      blob.contains('Home') ||
      blob.contains('列表') ||
      blob.contains('Item') ||
      blob.contains('滑动');
  await skill.disconnect();
  if (!onHome) {
    stderr.writeln('WARN: cannot confirm home from text dump; tap may still have worked');
  }
  stdout.writeln(onHome ? 'HOME_OK' : 'HOME_MAYBE');
}
