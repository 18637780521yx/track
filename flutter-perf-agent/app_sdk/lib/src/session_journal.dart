import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'manual_gesture_recorder.dart';
import 'sdk_report_writer.dart';
import 'transition_leak_tracker.dart';
import 'transition_ledger.dart';

/// In-app authoritative session ledger for MCP + manual steps.
class SessionJournal {
  SessionJournal._();
  static final SessionJournal instance = SessionJournal._();

  String? sessionId;
  String? testName;
  DateTime? startedAt;
  String? mode;
  String reportsDir = 'reports';
  bool manualRecording = true;
  bool autoSessionOnManual = true;

  final List<StepResult> steps = [];
  final List<AlertItem> alerts = [];

  /// While > 0, [ManualGestureRecorder] ignores pointer events (MCP synthetic).
  int mcpGuardDepth = 0;

  int _stepSeq = 0;

  bool get isActive => sessionId != null;

  bool get suppressManual => mcpGuardDepth > 0;

  void beginMcpGuard() => mcpGuardDepth++;

  void endMcpGuard() {
    if (mcpGuardDepth > 0) mcpGuardDepth--;
  }

  String nextStepId() {
    _stepSeq++;
    return 'step_$_stepSeq';
  }

  void start({
    required String sessionId,
    required String testName,
    String? mode,
    String? reportsDir,
    bool? manualRecording,
    bool? autoSessionOnManual,
  }) {
    this.sessionId = sessionId;
    this.testName = testName;
    startedAt = DateTime.now();
    this.mode = mode ??
        (kReleaseMode
            ? 'release'
            : (kProfileMode ? 'profile' : 'debug'));
    if (reportsDir != null && reportsDir.isNotEmpty) {
      this.reportsDir = reportsDir;
    }
    if (manualRecording != null) this.manualRecording = manualRecording;
    if (autoSessionOnManual != null) {
      this.autoSessionOnManual = autoSessionOnManual;
    }
    steps.clear();
    alerts.clear();
    _stepSeq = 0;
    mcpGuardDepth = 0;
    ManualGestureRecorder.instance.resetRouteTracking();
    TransitionLedger.instance.reset();
    TransitionLeakTracker.instance.clear();
    ManualGestureRecorder.instance.ensureStarted();
    debugPrint(
      '[SessionJournal] start $sessionId ($testName) '
      'manual=$manualRecording reportsDir=${this.reportsDir}',
    );
  }

  /// Start a manual-only session if none is active.
  bool ensureManualSession() {
    if (isActive) return true;
    if (!autoSessionOnManual) return false;
    start(
      sessionId: 'manual_${DateTime.now().millisecondsSinceEpoch}',
      testName: '手动录制',
      manualRecording: true,
    );
    return true;
  }

  void addStep(StepResult step) {
    if (!isActive) return;
    steps.add(step);
    _rebuildAlerts();
  }

  /// MCP 路由章会多次 upsert 同一 [stepId]；手动仍用 [addStep] 追加。
  void upsertStep(StepResult step) {
    if (!isActive) return;
    final i = steps.indexWhere((s) => s.stepId == step.stepId);
    if (i >= 0) {
      steps[i] = step;
    } else {
      steps.add(step);
    }
    _rebuildAlerts();
  }

  void addStepFromJson(Map<String, dynamic> json) {
    upsertStep(StepResult.fromJson(json));
  }

  void upsertStepFromJson(Map<String, dynamic> json) {
    upsertStep(StepResult.fromJson(json));
  }

  void _rebuildAlerts() {
    alerts
      ..clear()
      ..addAll([for (final s in steps) ...s.alerts]);
  }

  /// Refresh `live_<sessionId>.{json,html}` from the current journal.
  Future<SdkReportPaths?> writeLiveReport() async {
    if (!isActive || startedAt == null || steps.isEmpty) return null;
    return SdkReportWriter.writeLive(
      sessionId: sessionId!,
      testName: testName ?? 'unnamed',
      startedAt: startedAt!,
      mode: mode,
      reportsDir: reportsDir,
      steps: List<StepResult>.from(steps),
      alerts: List<AlertItem>.from(alerts),
    );
  }

  Future<SdkReportPaths?> stopAndWriteReport({
    Map<String, dynamic>? extra,
    bool writeReport = true,
  }) async {
    if (!isActive || startedAt == null) {
      _clear();
      return null;
    }
    SdkReportPaths? paths;
    if (writeReport && steps.isNotEmpty) {
      paths = await SdkReportWriter.write(
        sessionId: sessionId!,
        testName: testName ?? 'unnamed',
        startedAt: startedAt!,
        mode: mode,
        reportsDir: reportsDir,
        steps: List<StepResult>.from(steps),
        alerts: List<AlertItem>.from(alerts),
        extra: extra,
      );
      debugPrint(
        '[SessionJournal] stop → ${paths.jsonPath} / ${paths.htmlPath} '
        '(${steps.length} steps)',
      );
    } else {
      debugPrint(
        '[SessionJournal] stop without report '
        '(steps=${steps.length}, writeReport=$writeReport)',
      );
    }
    _clear();
    return paths;
  }

  void _clear() {
    sessionId = null;
    testName = null;
    startedAt = null;
    steps.clear();
    alerts.clear();
    mcpGuardDepth = 0;
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'testName': testName,
        'startedAt': startedAt?.toIso8601String(),
        'mode': mode,
        'stepCount': steps.length,
        'alertCount': alerts.length,
        'manualRecording': manualRecording,
        'mcpGuardDepth': mcpGuardDepth,
        'steps': steps.map((s) => s.toJson(includeScreenshotDataUri: false)).toList(),
        'alerts': alerts.map((a) => a.toJson()).toList(),
      };
}
