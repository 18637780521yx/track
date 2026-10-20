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
    required this.devtoolsSamplingEnabled,
    required this.devtoolsHttpEnabled,
    required this.devtoolsLoggingEnabled,
    required this.devtoolsClearCpuEachStep,
    required this.devtoolsCpuTopN,
    required this.devtoolsArtifactRawTraces,
    required this.debuggerPauseAllowed,
    required this.heapIncreaseWarningMB,
    required this.coldStartRelaunch,
    required this.coldStartAppPath,
    required this.coldStartMaxWaitMs,
    required this.ttffWarningMs,
    required this.leakTrackEnabled,
    required this.transitionSettleMs,
    required this.leakConfirmRounds,
    required this.leakRssRetainMb,
    required this.sleuthBindEnabled,
    required this.alertOnWeakRef,
    required this.requireMultiRound,
    required this.alertOnSleuthOnly,
    required this.alertOnRssRetain,
    required this.leakVmDeepProbe,
    this.repoRoot,
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

  final bool devtoolsSamplingEnabled;
  final bool devtoolsHttpEnabled;
  final bool devtoolsLoggingEnabled;
  final bool devtoolsClearCpuEachStep;
  final int devtoolsCpuTopN;
  final bool devtoolsArtifactRawTraces;
  final bool debuggerPauseAllowed;
  final double heapIncreaseWarningMB;

  /// Kill + relaunch the macOS `.app` before recording the cold_start step.
  final bool coldStartRelaunch;

  /// Absolute or repo-relative path to `example_app.app` (or similar).
  final String? coldStartAppPath;

  final int coldStartMaxWaitMs;
  final double ttffWarningMs;

  /// PRD / App SDK transition leak knobs (pushed on session/start).
  final bool leakTrackEnabled;
  final int transitionSettleMs;
  final int leakConfirmRounds;
  final double leakRssRetainMb;
  final bool sleuthBindEnabled;
  final bool alertOnWeakRef;
  final bool requireMultiRound;
  final bool alertOnSleuthOnly;
  final bool alertOnRssRetain;
  final bool leakVmDeepProbe;

  final String? repoRoot;

  String get bridgeBaseUrl => 'http://$bridgeHost:$bridgePort';

  /// Body fragment for Bridge `POST /session/start`.
  Map<String, dynamic> get transitionPayload => {
        'leakTrackEnabled': leakTrackEnabled,
        'transitionSettleMs': transitionSettleMs,
        'leakConfirmRounds': leakConfirmRounds,
        'leakRssRetainMb': leakRssRetainMb,
        'sleuthBindEnabled': sleuthBindEnabled,
        'alertOnWeakRef': alertOnWeakRef,
        'requireMultiRound': requireMultiRound,
        'alertOnSleuthOnly': alertOnSleuthOnly,
        'alertOnRssRetain': alertOnRssRetain,
        'leakVmDeepProbe': leakVmDeepProbe,
      };

  String? resolveColdStartAppPath() {
    final raw = coldStartAppPath;
    if (raw == null || raw.trim().isEmpty) return null;
    if (p.isAbsolute(raw)) return raw;
    if (repoRoot != null) return p.normalize(p.join(repoRoot!, raw));
    return p.normalize(p.absolute(raw));
  }

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
    final transition =
        (json['transition'] as Map?)?.cast<String, dynamic>() ?? {};
    final devtools =
        (json['devtoolsSampling'] as Map?)?.cast<String, dynamic>() ?? {};
    final debugger =
        (json['debugger'] as Map?)?.cast<String, dynamic>() ?? {};
    final coldStart =
        (json['coldStart'] as Map?)?.cast<String, dynamic>() ?? {};

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
      // Default off: metrics are Sleuth-only; VM is for flutter_skill UI.
      devtoolsSamplingEnabled: devtools['enabled'] as bool? ?? false,
      devtoolsHttpEnabled: devtools['http'] as bool? ?? false,
      devtoolsLoggingEnabled: devtools['logging'] as bool? ?? false,
      devtoolsClearCpuEachStep: devtools['clearCpuEachStep'] as bool? ?? true,
      devtoolsCpuTopN: (devtools['cpuTopN'] as num?)?.toInt() ?? 10,
      devtoolsArtifactRawTraces:
          devtools['artifactRawTraces'] as bool? ?? false,
      debuggerPauseAllowed: debugger['pauseAllowed'] as bool? ?? false,
      heapIncreaseWarningMB:
          (thresholds['heapIncreaseWarningMB'] as num?)?.toDouble() ?? 8,
      coldStartRelaunch: coldStart['relaunch'] as bool? ?? false,
      coldStartAppPath: coldStart['appPath'] as String? ??
          'example_app/build/macos/Build/Products/Debug/example_app.app',
      coldStartMaxWaitMs:
          (coldStart['maxWaitMs'] as num?)?.toInt() ?? 45000,
      ttffWarningMs: (coldStart['ttffWarningMs'] as num?)?.toDouble() ??
          (thresholds['ttffWarningMs'] as num?)?.toDouble() ??
          1500,
      leakTrackEnabled: transition['leakTrackEnabled'] as bool? ?? true,
      transitionSettleMs:
          (transition['transitionSettleMs'] as num?)?.toInt() ?? 1500,
      leakConfirmRounds:
          (transition['leakConfirmRounds'] as num?)?.toInt() ?? 2,
      leakRssRetainMb:
          (transition['leakRssRetainMb'] as num?)?.toDouble() ?? 5,
      sleuthBindEnabled: transition['sleuthBindEnabled'] as bool? ?? true,
      alertOnWeakRef: transition['alertOnWeakRef'] as bool? ?? true,
      requireMultiRound: transition['requireMultiRound'] as bool? ?? false,
      alertOnSleuthOnly: transition['alertOnSleuthOnly'] as bool? ?? true,
      alertOnRssRetain: transition['alertOnRssRetain'] as bool? ?? true,
      leakVmDeepProbe: transition['leakVmDeepProbe'] as bool? ?? false,
      repoRoot: repoRoot,
    );
  }
}
