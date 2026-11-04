import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:fast_track_mcp_server/perf_mcp_server.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Path to perf_agent_config.json',
    )
    ..addOption(
      'reports-dir',
      help: 'Override reports output directory',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final result = parser.parse(args);
  if (result['help'] == true) {
    io.stderr.writeln('Fast Track MCP MCP Server (Phase1)');
    io.stderr.writeln(parser.usage);
    io.exit(0);
  }

  // Resolve config relative to package / repo root when possible.
  final scriptDir = io.File(io.Platform.script.toFilePath()).parent.path;
  final repoRoot = p.normalize(p.join(scriptDir, '..', '..'));
  final defaultConfig = p.join(repoRoot, 'perf_agent_config.json');
  final configPath = result['config'] as String? ?? defaultConfig;
  final reportsOverride = result['reports-dir'] as String?;

  final config = await FastTrackMcpConfig.load(
    configPath,
    reportsDirOverride: reportsOverride,
    repoRoot: repoRoot,
  );

  io.stderr.writeln(
    '[fast_track_mcp-mcp] bridge=${config.bridgeBaseUrl} reports=${config.reportsDir}',
  );

  PerfMcpServer(
    stdioChannel(input: io.stdin, output: io.stdout),
    config: config,
  );
}
