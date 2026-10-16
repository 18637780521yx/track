import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'html_report.dart';

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
  final List<StepResult> steps = [];
  final List<AlertItem> alerts = [];

  void addStep(StepResult step) => steps.add(step);

  void addAlert(AlertItem alert) => alerts.add(alert);
}

class ReportPaths {
  ReportPaths({required this.jsonPath, required this.htmlPath});

  final String jsonPath;
  final String htmlPath;
}

class ReportWriter {
  ReportWriter(this.config);

  final PerfAgentConfig config;

  Future<ReportPaths> writeReports(
    PerfSession session, {
    SleuthSnapshotData? sleuthFinal,
    SleuthDiagnoseData? sleuthDiagnose,
    String? sleuthSummaryMarkdown,
  }) async {
    final dir = Directory(config.reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final endedAt = DateTime.now();
    final htmlReport = {
      'schemaVersion': 6,
      'agent': 'flutter-perf-agent',
      'phase': 'sleuth_full',
      'version': '0.6.0',
      'metricsSource': 'sleuth_bridge',
      'envelope': 'code/data/msg',
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
      'steps': session.steps.map((s) => s.toJson()).toList(),
      'alerts': session.alerts.map((a) => a.toJson()).toList(),
      if (sleuthDiagnose != null) 'sleuthDiagnose': sleuthDiagnose.toJson(),
      if (sleuthSummaryMarkdown != null)
        'sleuthSummaryMarkdown': sleuthSummaryMarkdown,
      if (sleuthFinal != null) 'sleuthFinal': sleuthFinal.toJson(),
      'summary': {
        'stepCount': session.steps.length,
        'alertCount': session.alerts.length,
        'okSteps': session.steps.where((s) => s.ok).length,
      },
      'note':
          '完整 Sleuth 快照经 PerfBridge。UI 仍用 flutter_skill（VM）。'
          'GC/堆等需 Sleuth 连上 VM：flutter run --profile --no-dds。',
    };

    final jsonSteps = session.steps
        .map((s) => s.toJson(includeScreenshotDataUri: false))
        .toList();
    final jsonReport = {
      ...htmlReport,
      'steps': jsonSteps,
    };

    final safeName = session.testName
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fff\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final stamp = endedAt.toIso8601String().replaceAll(':', '-');
    final base = '${stamp}_${safeName}_${session.sessionId}';
    final jsonPath = p.join(dir.path, '$base.json');
    final htmlPath = p.join(dir.path, '$base.html');

    await File(jsonPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(jsonReport),
    );
    await File(htmlPath).writeAsString(buildHtmlReport(htmlReport));

    return ReportPaths(jsonPath: jsonPath, htmlPath: htmlPath);
  }

  List<AlertItem> evaluateDiff(
    PerfDiffData diff, {
    required String stepId,
    required String action,
    SleuthIssuesData? sleuthIssues,
  }) {
    final alerts = <AlertItem>[];
    final memMb = diff.memoryDeltaMb;
    if (memMb >= config.memoryIncreaseWarningMB) {
      alerts.add(
        AlertItem(
          type: 'memory_increase',
          stepId: stepId,
          action: action,
          message:
              'RSS 上涨 ${memMb.toStringAsFixed(2)} MB ≥ 阈值 ${config.memoryIncreaseWarningMB} MB',
          value: memMb,
          threshold: config.memoryIncreaseWarningMB,
        ),
      );
    }

    final p90After = diff.p90FrameMsAfter;
    if (p90After != null && p90After > config.maxFrameCostMs) {
      alerts.add(
        AlertItem(
          type: 'slow_frame',
          stepId: stepId,
          action: action,
          message:
              'P90帧耗时 ${p90After.toStringAsFixed(2)} ms > 阈值 ${config.maxFrameCostMs} ms',
          value: p90After,
          threshold: config.maxFrameCostMs,
        ),
      );
    }

    final jankDelta = diff.jankDelta;
    if (jankDelta != null && jankDelta > 0) {
      alerts.add(
        AlertItem(
          type: 'jank',
          stepId: stepId,
          action: action,
          message: '本次操作新增 Jank $jankDelta 次',
          value: jankDelta,
        ),
      );
    }

    if (diff.issuesAfter.length > diff.issuesBefore.length) {
      final newly =
          diff.issuesAfter.skip(diff.issuesBefore.length).take(5).toList();
      alerts.add(
        AlertItem(
          type: 'sleuth_issues',
          stepId: stepId,
          action: action,
          message:
              '操作后新增 Sleuth issue ${diff.issuesAfter.length - diff.issuesBefore.length} 条',
          value: newly,
        ),
      );
    }

    if (sleuthIssues != null) {
      final severe = <Map<String, dynamic>>[];
      for (final item in sleuthIssues.issues) {
        final sev = item.severity?.toLowerCase() ?? '';
        if (sev.contains('error') ||
            sev.contains('critical') ||
            sev.contains('warning')) {
          severe.add(item.toJson());
        }
      }
      if (severe.isNotEmpty) {
        alerts.add(
          AlertItem(
            type: 'sleuth_detector',
            stepId: stepId,
            action: action,
            message: 'Sleuth 当前有 ${severe.length} 条 warning+ issue',
            value: severe.take(8).toList(),
            totalIssues: sleuthIssues.issues.length,
          ),
        );
      }
    }

    return alerts;
  }
}
