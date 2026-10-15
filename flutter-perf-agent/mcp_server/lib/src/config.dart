import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class PerfAgentConfig {
  PerfAgentConfig({
    required this.bridgeHost,
    required this.bridgePort,
    required this.waitStableMs,
    required this.reportsDir,
    required this.maxFrameCostMs,
    required this.memoryIncreaseWarningMB,
    required this.slowRequestMs,
    required this.configPath,
  });

  final String bridgeHost;
  final int bridgePort;
  final int waitStableMs;
  final String reportsDir;
  final double maxFrameCostMs;
  final double memoryIncreaseWarningMB;
  final int slowRequestMs;
  final String configPath;

  String get bridgeBaseUrl => 'http://$bridgeHost:$bridgePort';

  static Future<PerfAgentConfig> load(
    String configPath, {
    String? reportsDirOverride,
    String? repoRoot,
  }) async {
    Map<String, dynamic> json = {};
    final file = File(configPath);
    if (await file.exists()) {
      json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    }

    final thresholds =
        (json['thresholds'] as Map?)?.cast<String, dynamic>() ?? {};

    var reportsDir = reportsDirOverride ??
        json['reportsDir'] as String? ??
        'reports';
    if (!p.isAbsolute(reportsDir) && repoRoot != null) {
      reportsDir = p.normalize(p.join(repoRoot, reportsDir));
    }

    return PerfAgentConfig(
      bridgeHost: json['bridgeHost'] as String? ?? '127.0.0.1',
      bridgePort: json['bridgePort'] as int? ?? 19288,
      waitStableMs: json['waitStableMs'] as int? ?? 500,
      reportsDir: reportsDir,
      maxFrameCostMs: (thresholds['maxFrameCostMs'] as num?)?.toDouble() ?? 16,
      memoryIncreaseWarningMB:
          (thresholds['memoryIncreaseWarningMB'] as num?)?.toDouble() ?? 5,
      slowRequestMs: (thresholds['slowRequestMs'] as num?)?.toInt() ?? 300,
      configPath: configPath,
    );
  }
}
