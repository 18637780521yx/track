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

  /// Drop session alerts matching [test] (e.g. replace memory_increase per step).
  void removeAlertsWhere(bool Function(AlertItem a) test) {
    alerts.removeWhere(test);
  }
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
      'version': '0.9.2',
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
        'leakTrackEnabled': config.leakTrackEnabled,
        'transitionSettleMs': config.transitionSettleMs,
        'leakConfirmRounds': config.leakConfirmRounds,
        'leakRssRetainMb': config.leakRssRetainMb,
        'sleuthBindEnabled': config.sleuthBindEnabled,
        'alertOnWeakRef': config.alertOnWeakRef,
        'requireMultiRound': config.requireMultiRound,
        'alertOnSleuthOnly': config.alertOnSleuthOnly,
        'alertOnRssRetain': config.alertOnRssRetain,
        'leakVmDeepProbe': config.leakVmDeepProbe,
        'sleuthPerfEnabled': config.sleuthPerfEnabled,
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

    // Mid-session overlay + legacy live/latest bookmarks are not the final report.
    Future<void> drop(String name) async {
      try {
        final f = File(p.join(dir.path, name));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }

    await drop('live_${session.sessionId}.json');
    await drop('live_${session.sessionId}.html');
    await drop('live.json');
    await drop('live.html');
    await drop('latest.json');
    await drop('latest.html');

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
      'version': '0.9.2',
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
        'leakTrackEnabled': config.leakTrackEnabled,
        'transitionSettleMs': config.transitionSettleMs,
        'leakConfirmRounds': config.leakConfirmRounds,
        'leakRssRetainMb': config.leakRssRetainMb,
        'sleuthBindEnabled': config.sleuthBindEnabled,
        'alertOnWeakRef': config.alertOnWeakRef,
        'requireMultiRound': config.requireMultiRound,
        'alertOnSleuthOnly': config.alertOnSleuthOnly,
        'alertOnRssRetain': config.alertOnRssRetain,
        'leakVmDeepProbe': config.leakVmDeepProbe,
        'sleuthPerfEnabled': config.sleuthPerfEnabled,
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
    if (config.memoryIncreaseAlertEnabled &&
        memMb >= config.memoryIncreaseWarningMB) {
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

    // D0 (0.9.5+): jank / slow_frame are emitted realtime by App SDK
    // FrameJankLatch (FrameVerdict). Keep jankDelta / p90 on step.diff as
    // window summary only — do not duplicate as AlertItem here.

    // Sleuth issue → alert (sustained_jank / gc_pressure / …). Gated.
    if (!config.sleuthPerfEnabled) {
      return alerts;
    }

    final seenIssue = <String>{};
    void addIssue(SleuthIssueItem item, {required bool newlyAdded}) {
      final rawId = (item.stableId ?? item.id ?? '').trim();
      if (rawId.isEmpty || rawId == 'jank_detected') return;
      final sev = (item.severity ?? '').toLowerCase();
      if (!(sev.contains('error') ||
          sev.contains('critical') ||
          sev.contains('warning'))) {
        return;
      }
      if (!seenIssue.add(rawId)) return;
      final title = item.title ?? item.detail ?? rawId;
      alerts.add(
        AlertItem(
          type: rawId,
          stepId: stepId,
          action: action,
          message: newlyAdded ? '新增：$title' : title,
          value: _issueValueMap(item, rawId: rawId),
        ),
      );
    }

    if (sleuthIssues != null) {
      final live = sleuthIssues.issues;
      final addedCount = (diff.issuesAfter.length - diff.issuesBefore.length)
          .clamp(0, live.length);
      final newlyAdded = addedCount > 0
          ? live.sublist((live.length - addedCount).clamp(0, live.length))
          : const <SleuthIssueItem>[];
      final newlyIds = {
        for (final i in newlyAdded)
          if ((i.stableId ?? i.id ?? '').trim().isNotEmpty)
            (i.stableId ?? i.id)!.trim(),
      };
      for (final item in live) {
        addIssue(item, newlyAdded: newlyIds.contains(
          (item.stableId ?? item.id ?? '').trim(),
        ));
      }
    } else if (diff.issuesAfter.length > diff.issuesBefore.length) {
      // No structured list — expand string titles into best-effort types.
      for (final s in diff.issuesAfter
          .skip(diff.issuesBefore.length)
          .take(8)) {
        final type = _guessTypeFromText(s);
        if (type == null || type == 'jank_detected') continue;
        if (!seenIssue.add(type)) continue;
        alerts.add(
          AlertItem(
            type: type,
            stepId: stepId,
            action: action,
            message: s.length > 120 ? '${s.substring(0, 120)}…' : s,
            value: <String, dynamic>{
              'title': s,
              'stableId': type,
              'source': 'mcp_diff_expand',
            },
          ),
        );
      }
    }

    return alerts;
  }

  static Map<String, dynamic> _issueValueMap(
    SleuthIssueItem item, {
    required String rawId,
  }) {
    String? clip(String? s, [int max = 160]) {
      if (s == null || s.isEmpty) return null;
      final t = s.trim();
      if (t.length <= max) return t;
      return '${t.substring(0, max)}…';
    }

    return <String, dynamic>{
      'stableId': rawId,
      if (item.title != null) 'title': clip(item.title, 120),
      if (item.severity != null) 'severity': item.severity,
      if (item.category != null) 'category': item.category,
      if (item.fixHint != null) 'fixHint': clip(item.fixHint),
      if (item.detail != null) 'detail': clip(item.detail, 200),
      'source': 'mcp_diff',
    };
  }

  static String? _guessTypeFromText(String text) {
    final t = text.toLowerCase();
    if (t.contains('sustained jank')) return 'sustained_jank';
    if (t.contains('raster dominance')) return 'raster_dominance';
    if (t.contains('gc pressure')) return 'gc_pressure';
    if (t.contains('heap growing')) return 'heap_growing';
    if (t.contains('native memory')) return 'native_memory_growing';
    if (t.contains('heavy computation') || t.contains('heavy compute')) {
      return 'heavy_compute';
    }
    if (t.contains('shader')) return 'shader_compilation';
    return null;
  }
}
