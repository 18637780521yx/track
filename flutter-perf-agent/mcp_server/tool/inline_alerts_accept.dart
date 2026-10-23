import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

/// Offline accept: buildReportView inlines alerts into page/transition — no module=alert.
void main() {
  final report = <String, dynamic>{
    'testName': 'inline_alerts_accept',
    'sessionId': 'sess_inline',
    'mode': 'profile',
    'startedAt': '2026-01-01T00:00:00.000Z',
    'endedAt': '2026-01-01T00:00:05.000Z',
    'durationMs': 5000,
    'thresholds': {
      'maxFrameCostMs': 16,
      'memoryIncreaseWarningMB': 5,
      'slowRequestMs': 300,
    },
    'summary': {'stepCount': 2, 'okSteps': 2, 'alertCount': 3},
    'alerts': [
      {
        'type': 'jank',
        'message': '本次操作新增 Jank 2 次',
        'stepId': 'step_1',
        'action': 'tap',
        'value': 2,
      },
      {
        'type': 'memory_increase',
        'message': 'RSS 上涨',
        'stepId': 'step_1',
        'value': 6.2,
        'threshold': 5,
      },
      {
        'type': 'memory_leak',
        'message': 'XxxController 仍可达',
        'stepId': 'step_2',
        'value': {
          'alive': [
            {'name': 'XxxController'},
          ],
        },
      },
    ],
    'steps': [
      {
        'stepId': 'step_1',
        'action': 'tap',
        'route': '/login',
        'at': '2026-01-01T00:00:01.000Z',
        'ok': true,
        'source': 'mcp',
        'events': [
          {
            'type': 'action',
            'at': '2026-01-01T00:00:01.000Z',
            'label': 'tap:登录',
            'ok': true,
          },
          {
            'type': 'network',
            'at': '2026-01-01T00:00:01.100Z',
            'label': 'POST /api/login',
            'ok': true,
            'detail': {
              'method': 'POST',
              'url': '/api/login',
              'statusCode': 200,
              'durationMs': 312,
              'startedAt': '2026-01-01T00:00:01.100Z',
            },
          },
        ],
        'diff': {'jankDelta': 2, 'memoryDeltaMb': 6.2},
        'alerts': [],
      },
      {
        'stepId': 'step_2',
        'action': 'tap',
        'route': '/home#home',
        'at': '2026-01-01T00:00:02.000Z',
        'ok': true,
        'source': 'mcp',
        'events': [
          {
            'type': 'action',
            'at': '2026-01-01T00:00:02.000Z',
            'label': 'tap:login',
            'ok': true,
          },
          {
            'type': 'navigate',
            'at': '2026-01-01T00:00:02.050Z',
            'label': '/login → /home#home',
            'ok': true,
            'detail': {
              'from': '/login',
              'to': '/home#home',
              'transitionKind': 'route_change',
            },
          },
        ],
        'alerts': [],
      },
    ],
  };

  final view = buildReportView(report);
  final timeline =
      (view['timeline'] as List).cast<Map<String, dynamic>>();

  final modules = timeline.map((s) => s['module']?.toString()).toList();
  if (modules.contains('alert')) {
    stderr.writeln('FAIL: timeline still has module=alert: $modules');
    exit(2);
  }

  final pageLogin = timeline.cast<Map<String, dynamic>?>().firstWhere(
        (s) => s?['module'] == 'page' && s?['route'] == '/login',
        orElse: () => null,
      );
  if (pageLogin == null) {
    stderr.writeln('FAIL: missing page /login');
    exit(2);
  }
  final pageEvs =
      (pageLogin['events'] as List).cast<Map<String, dynamic>>();
  final pageAlertTypes = pageEvs
      .where((e) => e['type'] == 'alert')
      .map((e) => (e['detail'] as Map?)?['type']?.toString())
      .toList();
  if (!pageAlertTypes.contains('jank') ||
      !pageAlertTypes.contains('memory_increase')) {
    stderr.writeln('FAIL: page alerts=$pageAlertTypes');
    exit(2);
  }
  final actionIdx = pageEvs.indexWhere((e) => e['type'] == 'action');
  final jankIdx = pageEvs.indexWhere(
    (e) =>
        e['type'] == 'alert' &&
        (e['detail'] as Map?)?['type']?.toString() == 'jank',
  );
  if (actionIdx < 0 || jankIdx < 0 || jankIdx < actionIdx) {
    stderr.writeln(
      'FAIL: jank should follow action (action=$actionIdx jank=$jankIdx)',
    );
    exit(2);
  }

  final transition = timeline.cast<Map<String, dynamic>?>().firstWhere(
        (s) => s?['module'] == 'transition',
        orElse: () => null,
      );
  if (transition == null) {
    stderr.writeln('FAIL: missing transition');
    exit(2);
  }
  final tEvs =
      (transition['events'] as List).cast<Map<String, dynamic>>();
  final hasLeak = tEvs.any(
    (e) =>
        e['type'] == 'alert' &&
        (e['detail'] as Map?)?['type']?.toString() == 'memory_leak',
  );
  if (!hasLeak) {
    stderr.writeln('FAIL: transition missing leak alert: $tEvs');
    exit(2);
  }

  final html = buildHtmlReport({...report, 'view': view});
  if (html.contains('data-filter="alert"') || html.contains('>性能报告</')) {
    stderr.writeln('FAIL: HTML still has 性能报告 filter/chip');
    exit(2);
  }
  if (!html.contains('jank:+2') && !html.contains('jank')) {
    stderr.writeln('FAIL: HTML missing jank alert label');
    exit(2);
  }

  stdout.writeln(
    'PASS: modules=$modules pageAlerts=$pageAlertTypes '
    'transitionEvents=${tEvs.map((e) => e['type']).toList()}',
  );
  stdout.writeln(jsonEncode({
    'segmentCount': timeline.length,
    'modules': modules,
  }));
}
