import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class PerfAgentConfig {
  PerfAgentConfig({
    required this.bridgeHost,
    required this.bridgePort,
    required this.waitStableMs,
    required this.postActionSettleMs,
    required this.navigationWaitMs,
    required this.maxRetries,
    required this.retryDelayMs,
    required this.captureScreenshots,
    required this.debugLog,
    required this.reportsDir,
    required this.maxFrameCostMs,
    required this.memoryIncreaseWarningMB,
    required this.slowRequestMs,
    required this.configPath,
  });

  final String bridgeHost;
  final int bridgePort;
  final int waitStableMs;
  final int postActionSettleMs;
  final int navigationWaitMs;
  final int maxRetries;
  final int retryDelayMs;
  final bool captureScreenshots;
  final bool debugLog;
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
      postActionSettleMs: json['postActionSettleMs'] as int? ?? 400,
      navigationWaitMs: json['navigationWaitMs'] as int? ?? 800,
      maxRetries: json['maxRetries'] as int? ?? 2,
      retryDelayMs: json['retryDelayMs'] as int? ?? 300,
      captureScreenshots: json['captureScreenshots'] as bool? ?? true,
      debugLog: json['debugLog'] as bool? ?? false,
      reportsDir: reportsDir,
      maxFrameCostMs: (thresholds['maxFrameCostMs'] as num?)?.toDouble() ?? 16,
      memoryIncreaseWarningMB:
          (thresholds['memoryIncreaseWarningMB'] as num?)?.toDouble() ?? 5,
      slowRequestMs: (thresholds['slowRequestMs'] as num?)?.toInt() ?? 300,
      configPath: configPath,
    );
  }
}
