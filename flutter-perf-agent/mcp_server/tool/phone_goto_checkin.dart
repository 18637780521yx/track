import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/src/flutter_skill_vm_client.dart';
import 'package:flutter_perf_agent_mcp/src/visibility_assist.dart';

/// Drive physical phone: 我的 → 考勤 → 签到 (scrollIntoView).
Future<void> main(List<String> args) async {
  final rawVm = args.isNotEmpty
      ? args.first
      : 'http://127.0.0.1:50310/zs6TgbI25xk=/';
  final client = FlutterSkillVmClient(
    FlutterSkillVmClient.normalizeWsUri(rawVm),
    debugLog: true,
    maxRetries: 1,
  );
  await client.ensureConnected();

  Future<void> shot(String name) async {
    final b64 = await client.screenshotBase64(maxWidth: 720);
    if (b64 == null || b64.isEmpty) return;
    final dir = Directory(
      '${Directory.current.parent.path}/reports/screenshots/phone_yx',
    );
    await dir.create(recursive: true);
    final path = '${dir.path}/$name.png';
    await File(path).writeAsBytes(base64Decode(b64));
    stdout.writeln('saved $path');
  }

  Future<void> tapSmart(String target) async {
    stdout.writeln('tapEnsuringVisible:$target');
    final r = await VisibilityAssist.tapEnsuringVisible(client, target: target);
    stdout.writeln('  path=${r['path']} success=${r['success']} match=${r['match']}');
    if (r['success'] != true) {
      stdout.writeln('  full=$r');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final route = await client.getCurrentRoute();
    stdout.writeln('  route=${route['route']}');
  }

  await shot('20_start');
  await tapSmart('我的');
  await shot('21_mine');
  await tapSmart('考勤');
  await shot('22_checking');
  await tapSmart('签到');
  await Future<void>.delayed(const Duration(milliseconds: 2000));
  final route = await client.getCurrentRoute();
  stdout.writeln('final route=$route');
  await shot('23_checkin');

  await client.disconnect();
}
