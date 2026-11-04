import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

import '../lib/src/screenshot_hydrate.dart';

/// Rebuild HTML from an existing report JSON.
///
///   dart run tool/rebuild_html.dart path/to/report.json
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/rebuild_html.dart <report.json>');
    exit(2);
  }
  final jsonPath = p.normalize(args.first);
  final htmlPath = p.setExtension(jsonPath, '.html');
  final report =
      jsonDecode(await File(jsonPath).readAsString()) as Map<String, dynamic>;
  await hydrateReportScreenshots(report);
  // Recompute view (timeline clamp etc.) then HTML.
  report['view'] = buildReportView(report);
  await File(htmlPath).writeAsString(buildHtmlReport(report));
  // Keep JSON without data-URIs (paths only).
  final jsonOut = Map<String, dynamic>.from(report);
  _stripDataUris(jsonOut);
  jsonOut['view'] = buildReportView(jsonOut);
  await File(jsonPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(jsonOut),
  );
  stdout.writeln('rewrote $jsonPath + $htmlPath');
}

void _stripDataUris(Map<String, dynamic> report) {
  final steps = report['steps'];
  if (steps is! List) return;
  for (final s in steps) {
    if (s is! Map) continue;
    s.remove('screenshotDataUri');
    final events = s['events'];
    if (events is! List) continue;
    for (final e in events) {
      if (e is Map) e.remove('screenshotDataUri');
    }
  }
}
