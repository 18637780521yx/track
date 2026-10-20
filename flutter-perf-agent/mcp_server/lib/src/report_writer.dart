import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
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
  final List<StepResult> steps = [];
  final List<AlertItem> alerts = [];

  void addStep(StepResult step) => steps.add(step);

  void replaceLastStep(StepResult step) {
    if (steps.isEmpty) {
      steps.add(step);
    } else {
      steps[steps.length - 1] = step;
    }
  }

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
    final stepsJson = session.steps.map((s) => s.toJson()).toList();
    final alertsJson = session.alerts.map((a) => a.toJson()).toList();
    final baseReport = <String, dynamic>{
      'schemaVersion': 9,
      'agent': 'flutter-perf-agent',
      'phase': 'sleuth_full',
      'version': '0.8.1',
      'metricsSource': 'sleuth_bridge',
      'reportOwner': 'mcp_server',
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
        'ttffWarningMs': config.ttffWarningMs,
      },
      'steps': stepsJson,
      'alerts': alertsJson,
      if (sleuthDiagnose != null) 'sleuthDiagnose': sleuthDiagnose.toJson(),
      if (sleuthSummaryMarkdown != null)
        'sleuthSummaryMarkdown': sleuthSummaryMarkdown,
      if (sleuthFinal != null) 'sleuthFinal': sleuthFinal.toJson(),
      'summary': {
        'stepCount': session.steps.length,
        'alertCount': session.alerts.length,
        'okSteps': session.steps.where((s) => s.ok).length,
        'networkRequestCount': session.steps
            .fold<int>(0, (n, s) => n + s.networkRequests.length),
      },
      'note':
          '全会话时间线内嵌模块（启动/页面/转场/告警）；首步 cold_start。'
          '完整 Sleuth 快照经 PerfBridge；UI 用 flutter_skill（VM）。'
          '步骤含 networkRequests（完整抓包：URL/头/体）。'
          'GC/堆等需：flutter run --profile --no-dds。',
    };
    final view = buildReportView(baseReport);
    final htmlReport = {...baseReport, 'view': view};

    final jsonSteps = session.steps
        .map((s) => s.toJson(includeScreenshotDataUri: false))
        .toList();
    final jsonReport = {
      ...htmlReport,
      'steps': jsonSteps,
      'view': buildReportView({...baseReport, 'steps': jsonSteps}),
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

  /// 会话进行中覆盖写入 live 报告（每步 UI 动作后调用）。
  Future<ReportPaths> writeLiveReports(PerfSession session) async {
    final dir = Directory(config.reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final now = DateTime.now();
    final stepsJson = session.steps
        .map((s) => s.toJson(includeScreenshotDataUri: false))
        .toList();
    final liveBody = <String, dynamic>{
      'schemaVersion': 9,
      'agent': 'flutter-perf-agent',
      'phase': 'sleuth_full',
      'version': '0.8.1',
      'live': true,
      'metricsSource': 'sleuth_bridge',
      'reportOwner': 'mcp_server',
      'envelope': 'code/data/msg',
      'sessionId': session.sessionId,
      'testName': session.testName,
      'mode': session.mode,
      'startedAt': session.startedAt.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'durationMs': now.difference(session.startedAt).inMilliseconds,
      'thresholds': {
        'maxFrameCostMs': config.maxFrameCostMs,
        'memoryIncreaseWarningMB': config.memoryIncreaseWarningMB,
        'slowRequestMs': config.slowRequestMs,
        'ttffWarningMs': config.ttffWarningMs,
      },
      'steps': stepsJson,
      'alerts': session.alerts.map((a) => a.toJson()).toList(),
      'summary': {
        'stepCount': session.steps.length,
        'alertCount': session.alerts.length,
        'okSteps': session.steps.where((s) => s.ok).length,
        'networkRequestCount': session.steps
            .fold<int>(0, (n, s) => n + s.networkRequests.length),
      },
      'note':
          'Live report — 全会话时间线 + 模块分区；'
          'stop_perf_test 写出最终报告。',
    };
    final report = {...liveBody, 'view': buildReportView(liveBody)};
    final fileBase = 'live_${session.sessionId}';
    final jsonPath = p.join(dir.path, '$fileBase.json');
    final htmlPath = p.join(dir.path, '$fileBase.html');
    await File(jsonPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    await File(htmlPath).writeAsString(buildHtmlReport(report));
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
