import 'dart:convert';
import 'dart:io';

import 'package:fast_track_mcp_server/src/flutter_skill_vm_client.dart';
import 'package:fast_track_mcp_server/src/visibility_assist.dart';

/// Physical phone: login → 我的 → 考勤 → 签到 + screenshots.
///
///   dart run tool/phone_login_checkin.dart <vmServiceUri> [phone] [password]
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/phone_login_checkin.dart <vmUri> [phone] [password]',
    );
    exit(2);
  }
  final rawVm = args[0];
  final phone = args.length > 1 ? args[1] : '15565297553';
  final password = args.length > 2 ? args[2] : '123qwe,.';

  final client = FlutterSkillVmClient(
    FlutterSkillVmClient.normalizeWsUri(rawVm),
    debugLog: true,
    maxRetries: 1,
  );
  await client.ensureConnected();

  final shotDir = Directory(
    '${Directory.current.parent.path}/reports/screenshots/phone_yx_checkin',
  );
  await shotDir.create(recursive: true);

  Future<void> shot(String name) async {
    final b64 = await client.screenshotBase64(maxWidth: 900);
    if (b64 == null || b64.isEmpty) {
      stdout.writeln('screenshot empty: $name');
      return;
    }
    final path = '${shotDir.path}/$name.png';
    await File(path).writeAsBytes(base64Decode(b64));
    stdout.writeln('saved $path');
  }

  Future<Map<String, dynamic>> tapSmart(String target) async {
    stdout.writeln('tap:$target');
    final r = await VisibilityAssist.tapEnsuringVisible(client, target: target);
    stdout.writeln('  ok=${r['success']} path=${r['path']}');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return r;
  }

  Future<void> typeInto(String target, String text) async {
    stdout.writeln('input:$target = ${target.contains('密码') ? '***' : text}');
    // Clear then type via enterText
    final r = await client.enterText(text: text, target: target);
    stdout.writeln('  enterText ok=${FlutterSkillVmClient.isOk(r)} raw=$r');
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  await shot('00_start');
  final route0 = await client.getCurrentRoute();
  stdout.writeln('route0=$route0');

  // Login page hints from login_widget_view.dart
  await typeInto('请输入账号', phone);
  await typeInto('请输入密码', password);

  // Protocol may already be checked in test env; tap checkbox text if visible.
  final interactive = await client.inspectInteractive();
  stdout.writeln('interactive keys=${interactive.keys}');
  await shot('01_filled');

  await tapSmart('登录');
  await Future<void>.delayed(const Duration(seconds: 3));
  await shot('02_after_login');
  final route1 = await client.getCurrentRoute();
  stdout.writeln('route_after_login=$route1');

  await tapSmart('我的');
  await shot('03_mine');
  await tapSmart('考勤');
  await shot('04_checking');
  await tapSmart('签到');
  await Future<void>.delayed(const Duration(seconds: 2));
  final route2 = await client.getCurrentRoute();
  stdout.writeln('final_route=$route2');
  await shot('05_checkin');

  await client.disconnect();
  stdout.writeln('DONE shots in ${shotDir.path}');
}
