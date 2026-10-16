import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'html_report.dart';
import 'report_writer.dart';

/// Export / import session snapshots.
class SnapshotIo {
  static Future<String> exportSession({
    required PerfSession session,
    required String reportsDir,
    Map<String, dynamic>? extra,
  }) async {
    final dir = Directory(p.join(reportsDir, 'artifacts', session.sessionId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final payload = {
      'schemaVersion': 2,
      'kind': 'flutter-perf-agent-session-snapshot',
      'exportedAt': DateTime.now().toIso8601String(),
      'sessionId': session.sessionId,
      'testName': session.testName,
      'mode': session.mode,
      'startedAt': session.startedAt.toIso8601String(),
      'steps': session.steps
          .map((s) => s.toJson(includeScreenshotDataUri: false))
          .toList(),
      'alerts': session.alerts.map((a) => a.toJson()).toList(),
      ...?extra,
    };
    final path = p.join(dir.path, 'session_snapshot.json');
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    return path;
  }

  static Future<ApiResponse<Map<String, dynamic>>> importSession({
    required String snapshotPath,
    required String reportsDir,
  }) async {
    final file = File(snapshotPath);
    if (!await file.exists()) {
      return ApiResponse.fail(
        ApiCodes.badRequest,
        'snapshot not found: $snapshotPath',
      );
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return ApiResponse.fail(ApiCodes.badRequest, 'invalid snapshot JSON');
    }
    final dir = Directory(reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final sid = decoded['sessionId']?.toString() ?? 'imported';
    final htmlPath = p.join(dir.path, '${stamp}_imported_$sid.html');
    final report = {
      'schemaVersion': 6,
      'agent': 'flutter-perf-agent',
      'phase': 'sleuth_full',
      'imported': true,
      'sessionId': sid,
      'testName': decoded['testName'] ?? 'imported',
      'mode': decoded['mode'],
      'startedAt': decoded['startedAt'],
      'endedAt': decoded['exportedAt'] ?? DateTime.now().toIso8601String(),
      'durationMs': null,
      'steps': decoded['steps'] ?? const [],
      'alerts': decoded['alerts'] ?? const [],
      'summary': {
        'stepCount': (decoded['steps'] as List?)?.length ?? 0,
        'alertCount': (decoded['alerts'] as List?)?.length ?? 0,
      },
      'note': 'Imported session snapshot (read-only).',
    };
    await File(htmlPath).writeAsString(buildHtmlReport(report));
    final copyJson = p.join(dir.path, '${stamp}_imported_$sid.json');
    await File(copyJson).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    return ApiResponse.ok({
      'htmlReportPath': htmlPath,
      'jsonReportPath': copyJson,
      'sessionId': sid,
    });
  }
}
