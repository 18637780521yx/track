import 'dart:convert';
import 'dart:io';

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../lib/src/screenshot_hydrate.dart';

/// Rebuild HTML for a report JSON (default: newest timestamped under reports/).
Future<void> main(List<String> args) async {
  final repo = p.normalize(p.join(Directory.current.path, '..'));
  File jsonFile;
  if (args.isNotEmpty) {
    jsonFile = File(args.first);
  } else {
    final dir = Directory(p.join(repo, 'reports'));
    if (!await dir.exists()) {
      stderr.writeln('missing ${dir.path}');
      exit(2);
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.json') &&
              !p.basename(f.path).startsWith('live'),
        )
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (files.isEmpty) {
      stderr.writeln('no timestamped report json in ${dir.path}');
      exit(2);
    }
    jsonFile = files.first;
  }
  if (!await jsonFile.exists()) {
    stderr.writeln('missing ${jsonFile.path}');
    exit(2);
  }
  final map = jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
  await hydrateReportScreenshots(map);
  map['view'] = buildReportView(map);
  final htmlPath = jsonFile.path.replaceAll(RegExp(r'\.json$'), '.html');
  final html = buildHtmlReport(map);
  await File(htmlPath).writeAsString(html);
  stdout.writeln('ok $htmlPath bytes=${html.length}');
}
