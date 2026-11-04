import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';
import 'package:path/path.dart' as p;

import 'screenshot_hydrate.dart';
import '../leak/transition_leak_tracker.dart';

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
  }) async {
    final dir = Directory(reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final endedAt = DateTime.now();
    final thr = {
      'maxFrameCostMs': 16,
      'memoryIncreaseWarningMB': 5,
      'slowRequestMs': 300,
      'ttffWarningMs': 1500,
      ..._transitionThresholds(),
      ...?thresholds,
    };

    final mcpSteps =
        steps.where((s) => s.extra['source'] == 'mcp').length;
    final manualSteps =
        steps.where((s) => s.extra['source'] == 'manual').length;

    final stepsJson = steps.map((s) => s.toJson()).toList();
    final alertsJson = alerts.map((a) => a.toJson()).toList();
    final baseReport = <String, dynamic>{
      'schemaVersion': 9,
      'agent': 'fast_track_mcp',
      'phase': 'fast_track_mcp',
      'version': '0.9.2',
      'metricsSource': 'fast_track_mcp',
      'reportOwner': 'app_sdk',
      'envelope': 'code/data/msg',
      'sessionId': sessionId,
      'testName': testName,
      'mode': mode,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'durationMs': endedAt.difference(startedAt).inMilliseconds,
      'thresholds': thr,
      'steps': stepsJson,
      'alerts': alertsJson,
      'sleuthDiagnose': null,
      'sleuthSummaryMarkdown': null,
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
          '全会话时间线内嵌模块（启动/页面/转场/告警）；事件在模块内。'
          '权威账本在 App SDK（source=mcp|manual）。'
          '网络为 FastTrackMcp 全量抓包（头/体）；完整快照经 FastTrackMcpBridgeServer；UI 用 flutter_skill（VM）。'
          'GC/堆等需：flutter run --profile --no-dds。',
      ...?extra,
    };
    final htmlSteps = [for (final s in stepsJson) Map<String, dynamic>.from(s)];
    final htmlBody = {...baseReport, 'steps': htmlSteps};
    await hydrateReportScreenshots(htmlBody);
    final view = buildReportView(htmlBody);
    final htmlReport = {...htmlBody, 'view': view};

    final jsonReport = {
      ...htmlReport,
      'steps': steps
          .map((s) => s.toJson(includeScreenshotDataUri: false))
          .toList(),
      'view': buildReportView({
        ...baseReport,
        'steps': steps
            .map((s) => s.toJson(includeScreenshotDataUri: false))
            .toList(),
      }),
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

    // Drop mid-session overlay + legacy fixed bookmarks; final is authoritative.
    await _deleteQuiet(p.join(reportsDir, 'live_$sessionId.json'));
    await _deleteQuiet(p.join(reportsDir, 'live_$sessionId.html'));
    await _deleteQuiet(p.join(reportsDir, 'live.json'));
    await _deleteQuiet(p.join(reportsDir, 'live.html'));
    await _deleteQuiet(p.join(reportsDir, 'latest.json'));
    await _deleteQuiet(p.join(reportsDir, 'latest.html'));

    debugPrint('[SdkReportWriter] wrote $jsonPath + $htmlPath');
    return SdkReportPaths(jsonPath: jsonPath, htmlPath: htmlPath);
  }

  static Future<void> _deleteQuiet(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Mid-session live overlay (same HTML as final / manual).
  static Future<SdkReportPaths> writeLive({
    required String sessionId,
    required String testName,
    required DateTime startedAt,
    required String reportsDir,
    required List<StepResult> steps,
    required List<AlertItem> alerts,
    String? mode,
    Map<String, dynamic>? thresholds,
  }) async {
    final dir = Directory(reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final now = DateTime.now();
    final thr = {
      'maxFrameCostMs': 16,
      'memoryIncreaseWarningMB': 5,
      'slowRequestMs': 300,
      'ttffWarningMs': 1500,
      ..._transitionThresholds(),
      ...?thresholds,
    };
    final mcpSteps = steps.where((s) => s.extra['source'] == 'mcp').length;
    final manualSteps =
        steps.where((s) => s.extra['source'] == 'manual').length;
    final stepsJson =
        steps.map((s) => s.toJson(includeScreenshotDataUri: false)).toList();
    final body = <String, dynamic>{
      'schemaVersion': 9,
      'agent': 'fast_track_mcp',
      'phase': 'fast_track_mcp',
      'version': '0.9.2',
      'live': true,
      'metricsSource': 'fast_track_mcp',
      'reportOwner': 'app_sdk',
      'envelope': 'code/data/msg',
      'sessionId': sessionId,
      'testName': testName,
      'mode': mode,
      'startedAt': startedAt.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'durationMs': now.difference(startedAt).inMilliseconds,
      'thresholds': thr,
      'steps': stepsJson,
      'alerts': alerts.map((a) => a.toJson()).toList(),
      'summary': {
        'stepCount': steps.length,
        'alertCount': alerts.length,
        'okSteps': steps.where((s) => s.ok).length,
        'networkRequestCount':
            steps.fold<int>(0, (n, s) => n + s.networkRequests.length),
        'mcpSteps': mcpSteps,
        'manualSteps': manualSteps,
      },
      'note': 'Live — App SDK 账本（与手动同款 HTML）；stop 写出最终报告。',
    };
    final htmlBody = {
      ...body,
      'steps': [for (final s in stepsJson) Map<String, dynamic>.from(s)],
    };
    await hydrateReportScreenshots(htmlBody);
    final report = {...htmlBody, 'view': buildReportView(htmlBody)};
    // Session-scoped only (no fixed live.html / latest.html bookmark).
    final jsonPath = p.join(reportsDir, 'live_$sessionId.json');
    final htmlPath = p.join(reportsDir, 'live_$sessionId.html');
    await File(jsonPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        ...body,
        'view': buildReportView(body),
      }),
    );
    await File(htmlPath).writeAsString(buildHtmlReport(report));
    return SdkReportPaths(jsonPath: jsonPath, htmlPath: htmlPath);
  }

  /// Current [TransitionLeakTracker] knobs (after MCP session/start push).
  static Map<String, dynamic> _transitionThresholds() {
    final t = TransitionLeakTracker.instance;
    return {
      'leakTrackEnabled': t.enabled,
      'transitionSettleMs': t.settleMs,
      'leakConfirmRounds': t.leakConfirmRounds,
      'leakRssRetainMb': t.rssRetainMb,
      'alertOnWeakRef': t.alertOnWeakRef,
      'requireMultiRound': t.requireMultiRound,
      'alertOnRssRetain': t.alertOnRssRetain,
      'leakVmDeepProbe': t.leakVmDeepProbe,
    };
  }
}
