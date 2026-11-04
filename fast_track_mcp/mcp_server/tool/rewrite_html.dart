import 'dart:convert';
import 'dart:io';

import 'package:fast_track_mcp_server/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

import '../lib/src/screenshot_hydrate.dart';

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
  await hydrateReportScreenshots(report);
  final htmlPath = jsonFile.path.replaceAll(RegExp(r'\.json$'), '.html');
  await File(htmlPath).writeAsString(buildHtmlReport(report));
  stdout.writeln('rewrote $htmlPath');
}
