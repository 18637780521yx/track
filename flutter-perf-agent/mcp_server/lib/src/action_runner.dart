import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'perf_diff.dart';
import 'report_writer.dart';

typedef SkillAction = Future<Map<String, dynamic>> Function(
  FlutterSkillVmClient client,
);

/// Shared before → action → settle → after → Sleuth/RSS diff (+ screenshot).
class ActionRunner {
  ActionRunner({
    required this.config,
    required this.bridge,
    required this.reports,
    required this.session,
    required Future<FlutterSkillVmClient?> Function() ensureSkillClient,
    required int Function() nextStepId,
  })  : _ensureSkillClient = ensureSkillClient,
        _nextStepId = nextStepId;

  final PerfAgentConfig config;
  final BridgeClient bridge;
  final ReportWriter reports;
  final PerfSession session;
  final Future<FlutterSkillVmClient?> Function() _ensureSkillClient;
  final int Function() _nextStepId;

  void _log(String msg) {
    if (config.debugLog) {
      io.stderr.writeln('[perf-agent] $msg');
    }
  }

  Future<StepResult> run({
    required String action,
    required String actionLabel,
    required SkillAction skillAction,
    Map<String, dynamic>? extraStepFields,
    int? waitStableMs,
    int? extraSettleMs,
    Future<ApiResponse<TapLegacyData>> Function()? legacyFallback,
  }) async {
    final wait = waitStableMs ?? config.waitStableMs;
    final stepId = 'step_${_nextStepId()}';
    final t0 = DateTime.now();
    _log('begin $actionLabel ($stepId)');

    final beforeRes = await bridge.snapshot();
    if (!beforeRes.isOk || beforeRes.data == null) {
      final fail = StepResult(
        stepId: stepId,
        action: action,
        ok: false,
        driver: 'none',
        actionResult: ActionResult(
          success: false,
          error: 'before snapshot failed: ${beforeRes.msg}',
        ),
        at: DateTime.now().toIso8601String(),
        extra: {...?extraStepFields},
      );
      session.addStep(fail);
      return fail;
    }
    final before = beforeRes.data!.snapshot;

    ActionResult actionResult;
    var driver = 'flutter_skill';
    final client = await _ensureSkillClient();

    if (client != null) {
      try {
        await client.ensureConnected();
        final raw = await skillAction(client);
        actionResult = ActionResult.fromSkillMap(raw);
      } catch (e) {
        actionResult = ActionResult(
          success: false,
          driver: 'flutter_skill',
          error: 'flutter_skill $action failed: $e',
          detail: {'vmServiceUri': client.wsUri},
        );
      }

      if (!actionResult.success && legacyFallback != null) {
        _log('$actionLabel flutter_skill failed, trying legacy');
        driver = 'legacy_fallback';
        final legacy = await legacyFallback();
        final legacyOk = legacy.isOk && (legacy.data?.action.success ?? false);
        actionResult = ActionResult(
          success: legacyOk,
          driver: driver,
          detail: {
            'flutterSkill': actionResult.toJson(),
            'legacy': legacy.toJson(),
          },
          error: legacyOk ? null : (legacy.msg),
        );
      } else if (actionResult.success) {
        await bridge.waitStable(waitStableMs: wait);
        final settle = (extraSettleMs ?? 0) + config.postActionSettleMs;
        if (settle > 0) {
          await Future<void>.delayed(Duration(milliseconds: settle));
        }
      }
    } else if (legacyFallback != null) {
      driver = 'legacy';
      final legacy = await legacyFallback();
      final legacyOk = legacy.isOk && (legacy.data?.action.success ?? false);
      actionResult = ActionResult(
        success: legacyOk,
        driver: driver,
        detail: {'legacy': legacy.toJson()},
        error: legacyOk ? null : legacy.msg,
      );
    } else {
      actionResult = const ActionResult(
        success: false,
        error: 'no vmServiceUri and no legacy fallback',
      );
    }

    final afterRes = await bridge.snapshot();
    if (!afterRes.isOk || afterRes.data == null) {
      final fail = StepResult(
        stepId: stepId,
        action: action,
        ok: false,
        driver: driver,
        actionResult: ActionResult(
          success: false,
          driver: driver,
          error: 'after snapshot failed: ${afterRes.msg}',
          detail: actionResult.toJson(),
        ),
        at: DateTime.now().toIso8601String(),
        extra: {...?extraStepFields},
      );
      session.addStep(fail);
      return fail;
    }
    final after = afterRes.data!.snapshot;

    final diff = computePerfDiff(
      before: before,
      after: after,
      durationMs: DateTime.now().difference(t0).inMilliseconds,
    );

    final ok = actionResult.success;

    SleuthIssuesData? sleuthIssues;
    try {
      final issuesRes = await bridge.sleuthIssues(limit: 30);
      if (issuesRes.isOk) sleuthIssues = issuesRes.data;
    } catch (e) {
      _log('sleuth issues fetch failed: $e');
    }

    final alerts = reports.evaluateDiff(
      diff,
      stepId: stepId,
      action: actionLabel,
      sleuthIssues: sleuthIssues,
    );
    for (final a in alerts) {
      session.addAlert(a);
    }

    String? screenshotPath;
    String? screenshotDataUri;
    if (config.captureScreenshots && client != null) {
      try {
        await client.ensureConnected();
        final b64 = await client.screenshotBase64();
        if (b64 != null && b64.isNotEmpty) {
          screenshotPath = await _saveScreenshot(stepId, b64);
          screenshotDataUri = 'data:image/png;base64,$b64';
          _log('screenshot saved $screenshotPath');
        }
      } catch (e) {
        _log('screenshot failed: $e');
      }
    }

    final step = StepResult(
      stepId: stepId,
      action: action,
      ok: ok,
      driver: driver,
      actionResult: actionResult,
      diff: diff,
      sleuthIssues: sleuthIssues,
      alerts: alerts,
      screenshotPath: screenshotPath,
      screenshotDataUri: screenshotDataUri,
      at: DateTime.now().toIso8601String(),
      extra: {...?extraStepFields},
    );
    session.addStep(step);
    _log('end $actionLabel ok=$ok alerts=${alerts.length}');
    return step;
  }

  Future<String> _saveScreenshot(String stepId, String base64) async {
    final dir = io.Directory(
      p.join(config.reportsDir, 'screenshots', session.sessionId),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final path = p.join(dir.path, '$stepId.png');
    await io.File(path).writeAsBytes(base64Decode(base64));
    return path;
  }
}
