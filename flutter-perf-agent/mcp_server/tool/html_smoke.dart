import 'dart:io';
import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';

void main() {
  final html = buildHtmlReport({
    'testName': 'smoke',
    'sessionId': 'sess_1',
    'mode': 'profile',
    'startedAt': '2026-01-01T00:00:00Z',
    'endedAt': '2026-01-01T00:00:01Z',
    'durationMs': 1000,
    'thresholds': {
      'maxFrameCostMs': 16,
      'memoryIncreaseWarningMB': 5,
      'slowRequestMs': 300,
    },
    'summary': {'stepCount': 1, 'okSteps': 1, 'alertCount': 1},
    'alerts': [
      {
        'type': 'jank',
        'message': 'jank +1',
        'stepId': 'step_1',
        'action': 'scroll',
      },
    ],
    'steps': [
      {
        'stepId': 'step_1',
        'action': 'scroll',
        'ok': true,
        'driver': 'flutter_skill',
        'diff': {
          'durationMs': 100,
          'memoryDeltaMb': 0.1,
          'jankDelta': 1,
          'fpsBefore': 60,
          'fpsAfter': 55,
        },
        'alerts': [],
      },
    ],
    'note': 'smoke',
  });
  final out = File('../reports/smoke_phase2.html');
  out.writeAsStringSync(html);
  stdout.writeln('wrote ${out.path} (${html.length} bytes)');
}
