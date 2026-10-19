import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

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
  await File(htmlPath).writeAsString(buildHtmlReport(report));
  stdout.writeln('rewrote $htmlPath');
}
