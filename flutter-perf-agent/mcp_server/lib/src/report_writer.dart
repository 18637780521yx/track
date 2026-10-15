import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';

class PerfSession {
  PerfSession({
    required this.sessionId,
    required this.testName,
    required this.startedAt,
    this.mode,
  });

  final String sessionId;
  final String testName;
  final DateTime startedAt;
  final String? mode;
  final List<Map<String, dynamic>> steps = [];
  final List<Map<String, dynamic>> alerts = [];

  void addStep(Map<String, dynamic> step) => steps.add(step);

  void addAlert(Map<String, dynamic> alert) => alerts.add(alert);
}

class ReportWriter {
  ReportWriter(this.config);

  final PerfAgentConfig config;

  Future<String> writeJson(PerfSession session) async {
    final dir = Directory(config.reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final endedAt = DateTime.now();
    final report = {
      'schemaVersion': 1,
      'agent': 'flutter-perf-agent',
      'phase': 'phase1',
      'sessionId': session.sessionId,
      'testName': session.testName,
      'mode': session.mode,
      'startedAt': session.startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'durationMs': endedAt.difference(session.startedAt).inMilliseconds,
      'thresholds': {
        'maxFrameCostMs': config.maxFrameCostMs,
        'memoryIncreaseWarningMB': config.memoryIncreaseWarningMB,
        'slowRequestMs': config.slowRequestMs,
      },
      'steps': session.steps,
      'alerts': session.alerts,
      'summary': {
        'stepCount': session.steps.length,
        'alertCount': session.alerts.length,
        'okSteps': session.steps.where((s) => s['ok'] == true).length,
      },
      'note':
          '采集工具本身会引入额外开销；请优先使用 flutter run --profile 获取可信数据。',
    };

    final safeName = session.testName
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fff\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final fileName =
        '${endedAt.toIso8601String().replaceAll(':', '-')}_${safeName}_${session.sessionId}.json';
    final path = p.join(dir.path, fileName);
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    return path;
  }

  /// Evaluate thresholds against a tap diff and return alerts (may be empty).
  List<Map<String, dynamic>> evaluateDiff(
    Map<String, dynamic> diff, {
    required String stepId,
    required String action,
  }) {
    final alerts = <Map<String, dynamic>>[];
    final memMb = (diff['memoryDeltaMb'] as num?)?.toDouble();
    if (memMb != null && memMb >= config.memoryIncreaseWarningMB) {
      alerts.add({
        'type': 'memory_increase',
        'stepId': stepId,
        'action': action,
        'message':
            '内存上涨 ${memMb.toStringAsFixed(2)} MB ≥ 阈值 ${config.memoryIncreaseWarningMB} MB',
        'value': memMb,
        'threshold': config.memoryIncreaseWarningMB,
      });
    }

    final p90After = (diff['p90FrameMsAfter'] as num?)?.toDouble();
    if (p90After != null && p90After > config.maxFrameCostMs) {
      alerts.add({
        'type': 'slow_frame',
        'stepId': stepId,
        'action': action,
        'message':
            'P90帧耗时 ${p90After.toStringAsFixed(2)} ms > 阈值 ${config.maxFrameCostMs} ms',
        'value': p90After,
        'threshold': config.maxFrameCostMs,
      });
    }

    final jankDelta = diff['jankDelta'] as int?;
    if (jankDelta != null && jankDelta > 0) {
      alerts.add({
        'type': 'jank',
        'stepId': stepId,
        'action': action,
        'message': '本次操作新增 Jank $jankDelta 次',
        'value': jankDelta,
      });
    }

    return alerts;
  }
}
