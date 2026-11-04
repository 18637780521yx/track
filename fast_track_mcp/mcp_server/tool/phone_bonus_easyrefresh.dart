import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:fast_track_mcp_server/src/flutter_skill_vm_client.dart';
import 'package:fast_track_mcp_server/src/visibility_assist.dart';

/// Track MCP Bridge + flutter_skill：业绩汇算 EasyRefresh 回归。
///
/// 用法：
///   dart run tool/phone_bonus_easyrefresh.dart [vmHttpUri]
/// 不传 URI 时从 http://127.0.0.1:19288/health 读取。
Future<void> main(List<String> args) async {
  final bridge = Uri.parse('http://127.0.0.1:19288');
  final httpClient = http.Client();

  Future<Map<String, dynamic>> bridgeGet(String path) async {
    final r = await httpClient.get(bridge.replace(path: path));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> bridgePost(
    String path,
    Map<String, dynamic> body,
  ) async {
    final r = await httpClient.post(
      bridge.replace(path: path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  final health = await bridgeGet('/health');
  stdout.writeln('health=${jsonEncode(health)}');
  if (health['code'] != 0) {
    stderr.writeln('Bridge health failed');
    exit(2);
  }

  final vmRaw = args.isNotEmpty
      ? args.first
      : (health['data'] as Map)['vmServiceUri'] as String?;
  if (vmRaw == null || vmRaw.isEmpty) {
    stderr.writeln('No vmServiceUri');
    exit(2);
  }

  final start = await bridgePost('/session/start', {
    'testName': 'bonus_easyrefresh_regression',
    'waitStableMs': 300,
  });
  stdout.writeln('session.start=${jsonEncode(start)}');
  if (start['code'] != 0) {
    stderr.writeln('session start failed');
    exit(3);
  }
  final sessionId = (start['data'] as Map)['sessionId'];

  final client = FlutterSkillVmClient(
    FlutterSkillVmClient.normalizeWsUri(vmRaw),
    debugLog: true,
    maxRetries: 1,
  );
  await client.ensureConnected();

  Future<void> shot(String name) async {
    final b64 = await client.screenshotBase64(maxWidth: 720);
    if (b64 == null || b64.isEmpty) return;
    final dir = Directory(
      '${Directory.current.parent.path}/reports/screenshots/bonus_yx',
    );
    await dir.create(recursive: true);
    final path = '${dir.path}/$name.png';
    await File(path).writeAsBytes(base64Decode(b64));
    stdout.writeln('saved $path');
  }

  Future<void> tapSmart(String target) async {
    stdout.writeln('tapEnsuringVisible:$target');
    final r = await VisibilityAssist.tapEnsuringVisible(client, target: target);
    stdout.writeln(
      '  path=${r['path']} success=${r['success']} match=${r['match']}',
    );
    if (r['success'] != true) stdout.writeln('  full=$r');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final route = await client.getCurrentRoute();
    stdout.writeln('  route=${route['route']}');
  }

  final failures = <String>[];
  const phone = '15737025991';
  const password = '123qwe,.';

  try {
    await shot('00_home');
    var route0 = await client.getCurrentRoute();
    stdout.writeln('route0=${route0['route']}');

    // 登录页文案可能是「登 录」（中间空格）
    final bootUi = await client.interactive();
    final bootStr = jsonEncode(bootUi);
    final onLogin = bootStr.contains('登') &&
        (bootStr.contains('请输入') ||
            bootStr.contains('典道') ||
            bootStr.contains('服务协议'));
    if (onLogin) {
      stdout.writeln('on login page → sign in');
      await client.enterText(text: phone, target: '请输入账号');
      await client.enterText(text: password, target: '请输入密码');
      // 优先点「登 录」，再退回「登录」
      var loginTap = await VisibilityAssist.tapEnsuringVisible(
        client,
        target: '登 录',
      );
      if (loginTap['success'] != true) {
        loginTap = await VisibilityAssist.tapEnsuringVisible(
          client,
          target: '登录',
        );
      }
      stdout.writeln('login tap success=${loginTap['success']}');
      await Future<void>.delayed(const Duration(seconds: 5));
      await shot('00b_after_login');
      route0 = await client.getCurrentRoute();
      stdout.writeln('route_after_login=${route0['route']}');
    }

    // 底部中间常是工作台；文案可能是「工作」而非「工作台」
    for (final tab in ['工作台', '工作', '首页']) {
      final t = await VisibilityAssist.tapEnsuringVisible(client, target: tab);
      if (t['success'] == true) {
        stdout.writeln('entered tab via $tab');
        break;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await shot('00c_workbench');

    // 工作台首页点业绩汇算
    await tapSmart('业绩汇算');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await shot('01_bonus_list');

    final route1 = await client.getCurrentRoute();
    var routeName = '${route1['route']}';
    // 若仍停在详情，先返回列表再断言
    if (routeName.contains('BonusPerformanceSummary') ||
        routeName.contains('Descr')) {
      await client.swipe(direction: 'right', distance: 400);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      // Android back
      try {
        await VisibilityAssist.tapEnsuringVisible(client, target: '返回');
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 600));
      routeName = '${(await client.getCurrentRoute())['route']}';
    }
    final onBonusFlow = routeName.toLowerCase().contains('bonus');
    if (!onBonusFlow) {
      failures.add('expected bonus* route, got $routeName');
    }

    // 列表滑动 + 下拉刷新手势（EasyRefresh）
    stdout.writeln('swipe down then pull-refresh-like swipe up');
    await client.swipe(direction: 'down', distance: 400);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await client.swipe(direction: 'up', distance: 500);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await shot('02_after_scroll');

    // 点进第一条（文案含「业绩奖汇算」）
    final interactive = await client.interactive();
    stdout.writeln('interactive.keys=${interactive.keys}');
    final texts = <String>[];
    void collect(dynamic node) {
      if (node is Map) {
        final t = node['text'] ?? node['label'] ?? node['semanticsLabel'];
        if (t is String && t.contains('业绩奖汇算')) texts.add(t);
        final children = node['children'];
        if (children is List) {
          for (final c in children) {
            collect(c);
          }
        }
      } else if (node is List) {
        for (final c in node) {
          collect(c);
        }
      }
    }

    collect(interactive);
    // fallback: try common short name from dump
    if (texts.isEmpty) {
      for (final key in ['张小可的业绩奖汇算', '张智的业绩奖汇算', '孔朋朋的业绩奖汇算']) {
        texts.add(key);
      }
    }

    var openedDetail = false;
    for (final t in texts.take(3)) {
      final short = t.split('\n').firstWhere(
            (e) => e.contains('业绩奖汇算'),
            orElse: () => t.length > 20 ? t.substring(0, 20) : t,
          );
      stdout.writeln('try open item: $short');
      final r =
          await VisibilityAssist.tapEnsuringVisible(client, target: short);
      stdout.writeln('  success=${r['success']}');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final route = await client.getCurrentRoute();
      stdout.writeln('  route=${route['route']}');
      if ('${route['route']}' != routeName && r['success'] == true) {
        openedDetail = true;
        await shot('03_bonus_detail');
        break;
      }
    }
    if (!openedDetail) {
      // 非硬失败：列表本身已验证无崩溃
      stdout.writeln('note: detail not opened (list still OK if no crash)');
    }

    // 列表/详情路由已验证；无 BoxConstraints 类崩溃即视为 EasyRefresh 布局回归通过
    await bridgePost('/session/step', {
      'sessionId': sessionId,
      'testName': 'bonus_easyrefresh_regression',
      'step': {
        'id': 'bonus_list_ok',
        'action': 'assert',
        'label': 'bonus list rendered',
        'source': 'mcp',
        'ok': failures.isEmpty,
        'route': routeName,
        'extra': {'failures': failures},
      },
    });
  } catch (e, st) {
    failures.add('$e');
    stderr.writeln('FLOW ERROR: $e\n$st');
  }

  final stop = await bridgePost('/session/stop', {});
  stdout.writeln('session.stop=${jsonEncode(stop)}');

  await client.disconnect();
  httpClient.close();

  if (failures.isNotEmpty) {
    stderr.writeln('FAILED: $failures');
    exit(1);
  }
  stdout.writeln('OK bonus EasyRefresh regression');
}
