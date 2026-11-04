import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../lib/src/screenshot_compress.dart';

/// Smoke: page cover + compact rows + transition kind/warn.
Future<void> main() async {
  final tiny = img.Image(width: 40, height: 80);
  img.fill(tiny, color: img.ColorRgb8(30, 120, 80));
  final png = Uint8List.fromList(img.encodePng(tiny));
  final compressed = ScreenshotCompress.compress(png, maxWidth: 360);
  assert(compressed.ext == 'jpg', 'expected jpg, got ${compressed.ext}');
  assert(
    compressed.bytes.length < png.length * 2,
    'compressed should stay small',
  );

  final report = {
    'testName': '登录退出',
    'sessionId': 'mock_tl',
    'mode': 'profile',
    'startedAt': '2026-04-01T10:00:00.000Z',
    'endedAt': '2026-04-01T10:01:00.000Z',
    'durationMs': 60000,
    'thresholds': {'slowRequestMs': 300},
    'summary': {'stepCount': 3, 'okSteps': 3, 'alertCount': 1},
    'alerts': <Map<String, dynamic>>[],
    'steps': [
      {
        'stepId': 's0',
        'action': 'cold_start',
        'ok': true,
        'driver': 'sdk',
        'ttffMs': 432,
        'ttiMs': 812,
        'events': [
          {
            'type': 'cold_start',
            'at': '2026-04-01T10:00:00.100Z',
            'label': 'App 启动',
            'ok': true,
            'detail': {'kind': 'cold_start'},
          },
        ],
        'alerts': [],
        'networkRequests': [],
      },
      {
        'stepId': 's1',
        'action': 'tap',
        'route': '/login',
        'ok': true,
        'driver': 'manual',
        'source': 'manual',
        'at': '2026-04-01T10:00:10.000Z',
        'screenshotDataUri': compressed.dataUri,
        'screenshotPath': '/tmp/mock_login.jpg',
        'events': [
          {
            'type': 'action',
            'at': '2026-04-01T10:00:10.000Z',
            'label': 'input:password',
            'ok': true,
            'detail': {'route': '/login'},
          },
          {
            'type': 'action',
            'at': '2026-04-01T10:00:11.000Z',
            'label': 'tap:login',
            'ok': true,
            'detail': {'route': '/login'},
          },
          {
            'type': 'network',
            'at': '2026-04-01T10:00:11.200Z',
            'label': 'POST /api/login',
            'ok': true,
            'detail': {
              'method': 'POST',
              'url': 'https://x/api/login',
              'durationMs': 312,
              'statusCode': 200,
              'route': '/login',
            },
          },
          {
            'type': 'screenshot',
            'at': '2026-04-01T10:00:11.500Z',
            'label': '操作后截图',
            'ok': true,
            'screenshotDataUri': compressed.dataUri,
            'detail': {'route': '/login'},
          },
          {
            'type': 'navigate',
            'at': '2026-04-01T10:00:12.000Z',
            'label': '/login → /home#home',
            'ok': true,
            'detail': {
              'from': '/login',
              'to': '/home#home',
              'transitionKind': 'remove',
              'leak': {
                'aliveCount': 1,
                'alive': [
                  {'name': 'LoginController'},
                ],
                'evidence': 'weak_ref',
              },
            },
          },
        ],
        'alerts': [],
        'networkRequests': [],
      },
      {
        'stepId': 's2',
        'action': 'tap',
        'route': '/home#home',
        'ok': true,
        'driver': 'manual',
        'source': 'manual',
        'at': '2026-04-01T10:00:20.000Z',
        'screenshotDataUri': compressed.dataUri,
        'events': [
          {
            'type': 'network',
            'at': '2026-04-01T10:00:20.100Z',
            'label': 'GET /api/home/list',
            'ok': true,
            'detail': {
              'method': 'GET',
              'url': 'https://x/api/home/list',
              'durationMs': 180,
              'statusCode': 200,
              'route': '/home#home',
            },
          },
          {
            'type': 'action',
            'at': '2026-04-01T10:00:21.000Z',
            'label': 'tap:profile_button',
            'ok': true,
            'detail': {'route': '/home#home'},
          },
          {
            'type': 'screenshot',
            'at': '2026-04-01T10:00:21.200Z',
            'label': '操作后截图',
            'ok': true,
            'screenshotDataUri': compressed.dataUri,
            'detail': {'route': '/home#home'},
          },
        ],
        'alerts': [],
        'networkRequests': [],
      },
    ],
    'note': 'timeline mock smoke',
  };

  final html = buildHtmlReport(report);
  final out = File(
    p.join(Directory.current.parent.path, 'reports', 'timeline_mock_smoke.html'),
  );
  await out.parent.create(recursive: true);
  await out.writeAsString(html);

  final checks = {
    'page-body': html.contains('page-body'),
    'page-cover': html.contains('page-cover'),
    'action-rows': html.contains('action-rows'),
    'kind-chip': html.contains('kind-chip'),
    'tr-warn': html.contains('tr-warn'),
    'lifecycle TTFF': html.contains('TTFF'),
    'no screenshot row': !html.contains('操作后截图'),
  };
  for (final e in checks.entries) {
    stdout.writeln('${e.value ? 'ok' : 'FAIL'}  ${e.key}');
  }
  if (checks.values.any((v) => !v)) {
    stderr.writeln('smoke failed');
    exit(1);
  }
  stdout.writeln('wrote ${out.path} (${html.length} bytes)');
  stdout.writeln(
    'jpg ${compressed.bytes.length}B from png ${png.length}B '
    '(${jsonEncode({'ext': compressed.ext})})',
  );
}
