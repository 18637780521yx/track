import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_mcp/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

/// Rewrite HTML for the newest non-live report JSON (or a given path).
Future<void> main(List<String> args) async {
  final repoRoot = p.normalize(p.join(Directory.current.path, '..'));
  final reportsDir = p.join(repoRoot, 'reports');
  File jsonFile;
  if (args.isNotEmpty) {
    jsonFile = File(args.first);
  } else {
    final files = Directory(reportsDir)
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.json') &&
              !p.basename(f.path).startsWith('live_'),
        )
        .toList()
      ..sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );
    if (files.isEmpty) {
      stderr.writeln('no report json in $reportsDir');
      exit(2);
    }
    jsonFile = files.first;
  }
  final report =
      jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
  final htmlPath = jsonFile.path.replaceAll(RegExp(r'\.json$'), '.html');
  await File(htmlPath).writeAsString(buildHtmlReport(report));
  stdout.writeln('rewrote $htmlPath');
}
