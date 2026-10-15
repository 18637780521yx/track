import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'html_report.dart';
import 'report_writer.dart';

/// Export / import session snapshots (DevTools Performance I/O analogue).
class SnapshotIo {
  /// Write a portable JSON snapshot next to reports.
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
      'schemaVersion': 1,
      'kind': 'flutter-perf-agent-session-snapshot',
      'exportedAt': DateTime.now().toIso8601String(),
      'sessionId': session.sessionId,
      'testName': session.testName,
      'mode': session.mode,
      'startedAt': session.startedAt.toIso8601String(),
      'steps': session.steps.map((s) {
        final copy = Map<String, dynamic>.from(s)..remove('screenshotDataUri');
        return copy;
      }).toList(),
      'alerts': session.alerts,
      ...?extra,
    };
    final path = p.join(dir.path, 'session_snapshot.json');
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    return path;
  }

  /// Import a snapshot file and regenerate an HTML report.
  static Future<Map<String, dynamic>> importSession({
    required String snapshotPath,
    required String reportsDir,
  }) async {
    final file = File(snapshotPath);
    if (!await file.exists()) {
      return {'ok': false, 'error': 'snapshot not found: $snapshotPath'};
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return {'ok': false, 'error': 'invalid snapshot JSON'};
    }
    final dir = Directory(reportsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final sid = decoded['sessionId']?.toString() ?? 'imported';
    final htmlPath = p.join(dir.path, '${stamp}_imported_$sid.html');
    final report = {
      'schemaVersion': 4,
      'agent': 'flutter-perf-agent',
      'phase': 'devtools',
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
    return {
      'ok': true,
      'htmlReportPath': htmlPath,
      'jsonReportPath': copyJson,
      'sessionId': sid,
    };
  }
}
