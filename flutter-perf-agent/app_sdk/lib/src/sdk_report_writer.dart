import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

class SdkReportPaths {
  SdkReportPaths({required this.jsonPath, required this.htmlPath});

  final String jsonPath;
  final String htmlPath;

  Map<String, dynamic> toJson() => {
        'jsonPath': jsonPath,
        'htmlPath': htmlPath,
      };
}

/// Writes authoritative JSON + HTML using the **same** schema/HTML as MCP.
class SdkReportWriter {
  static Future<SdkReportPaths> write({
    required String sessionId,
    required String testName,
    required DateTime startedAt,
    required String reportsDir,
    required List<StepResult> steps,
    required List<AlertItem> alerts,
    String? mode,
    Map<String, dynamic>? extra,
    Map<String, dynamic>? thresholds,
    SleuthDiagnoseData? sleuthDiagnose,
    String? sleuthSummaryMarkdown,
    SleuthSnapshotData? sleuthFinal,
  }) async {
    final dir = Directory(reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final endedAt = DateTime.now();
    final thr = thresholds ??
        const {
          'maxFrameCostMs': 16,
          'memoryIncreaseWarningMB': 5,
          'slowRequestMs': 300,
          'ttffWarningMs': 1500,
        };

    final mcpSteps =
        steps.where((s) => s.extra['source'] == 'mcp').length;
    final manualSteps =
        steps.where((s) => s.extra['source'] == 'manual').length;

    // Same shape as mcp_server ReportWriter (schema 7+) so HTML matches.
    final htmlReport = {
      'schemaVersion': 8,
      'agent': 'flutter-perf-agent',
      'phase': 'sleuth_full',
      'version': '0.7.1',
      'metricsSource': 'sleuth_bridge',
      'reportOwner': 'app_sdk',
      'envelope': 'code/data/msg',
      'sessionId': sessionId,
      'testName': testName,
      'mode': mode,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'durationMs': endedAt.difference(startedAt).inMilliseconds,
      'thresholds': thr,
      'steps': steps.map((s) => s.toJson()).toList(),
      'alerts': alerts.map((a) => a.toJson()).toList(),
      if (sleuthDiagnose != null) 'sleuthDiagnose': sleuthDiagnose.toJson(),
      if (sleuthSummaryMarkdown != null)
        'sleuthSummaryMarkdown': sleuthSummaryMarkdown,
      if (sleuthFinal != null) 'sleuthFinal': sleuthFinal.toJson(),
      'summary': {
        'stepCount': steps.length,
        'alertCount': alerts.length,
        'okSteps': steps.where((s) => s.ok).length,
        'networkRequestCount':
            steps.fold<int>(0, (n, s) => n + s.networkRequests.length),
        'mcpSteps': mcpSteps,
        'manualSteps': manualSteps,
      },
      'note':
          '路由章 / 事件时间线 / 冷启动与 MCP 报告同一套 HTML。'
          '权威账本在 App SDK（source=mcp|manual）。'
          '完整 Sleuth 快照经 PerfBridge；UI 用 flutter_skill（VM）。'
          'GC/堆等需：flutter run --profile --no-dds。',
      ...?extra,
    };

    final jsonReport = {
      ...htmlReport,
      'steps': steps
          .map((s) => s.toJson(includeScreenshotDataUri: false))
          .toList(),
    };

    final safeName = testName
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fff\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final stamp = endedAt.toIso8601String().replaceAll(':', '-');
    // Same naming pattern as MCP: {stamp}_{name}_{sessionId}
    final base = '${stamp}_${safeName}_$sessionId';
    final jsonPath = p.join(reportsDir, '$base.json');
    final htmlPath = p.join(reportsDir, '$base.html');

    await File(jsonPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(jsonReport),
    );
    await File(htmlPath).writeAsString(buildHtmlReport(htmlReport));

    final liveJson = p.join(reportsDir, 'live_$sessionId.json');
    final liveHtml = p.join(reportsDir, 'live_$sessionId.html');
    final liveReport = {
      ...htmlReport,
      'live': true,
      'updatedAt': endedAt.toIso8601String(),
      'steps': steps
          .map((s) => s.toJson(includeScreenshotDataUri: false))
          .toList(),
    };
    await File(liveJson).writeAsString(
      const JsonEncoder.withIndent('  ').convert(liveReport),
    );
    await File(liveHtml).writeAsString(buildHtmlReport(liveReport));

    debugPrint('[SdkReportWriter] wrote $jsonPath (MCP-compatible HTML)');
    return SdkReportPaths(jsonPath: jsonPath, htmlPath: htmlPath);
  }
}
