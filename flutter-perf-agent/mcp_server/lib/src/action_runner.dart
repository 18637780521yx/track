import 'dart:io' as io;

import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'perf_diff.dart';
import 'report_writer.dart';

typedef SkillAction = Future<Map<String, dynamic>> Function(
  FlutterSkillVmClient client,
);

/// Shared before → action → wait → after → diff pipeline for MCP tools.
class ActionRunner {
  ActionRunner({
    required this.config,
    required this.bridge,
    required this.reports,
    required this.session,
    required String? Function() vmWsUri,
    required int Function() nextStepId,
  })  : _vmWsUri = vmWsUri,
        _nextStepId = nextStepId;

  final PerfAgentConfig config;
  final BridgeClient bridge;
  final ReportWriter reports;
  final PerfSession session;
  final String? Function() _vmWsUri;
  final int Function() _nextStepId;

  void _log(String msg) {
    if (config.debugLog) {
      io.stderr.writeln('[perf-agent] $msg');
    }
  }

  Future<Map<String, dynamic>> run({
    required String action,
    required String actionLabel,
    required SkillAction skillAction,
    Map<String, dynamic>? extraStepFields,
    int? waitStableMs,
    Future<Map<String, dynamic>> Function()? legacyFallback,
  }) async {
    final wait = waitStableMs ?? config.waitStableMs;
    final stepId = 'step_${_nextStepId()}';
    final t0 = DateTime.now();
    _log('begin $actionLabel ($stepId)');

    final beforeRes = await bridge.snapshot();
    if (beforeRes['ok'] != true) {
      return {
        'ok': false,
        'error': 'before snapshot failed',
        'detail': beforeRes,
      };
    }
    final before =
        (beforeRes['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};

    Map<String, dynamic> actionResult;
    var driver = 'flutter_skill';
    final uri = _vmWsUri();

    if (uri != null) {
      final client = FlutterSkillVmClient(
        uri,
        maxRetries: config.maxRetries,
        retryDelayMs: config.retryDelayMs,
        debugLog: config.debugLog,
      );
      try {
        await client.connect();
        actionResult = await skillAction(client);
      } catch (e) {
        actionResult = {
          'success': false,
          'error': 'flutter_skill $action failed: $e',
          'vmServiceUri': uri,
        };
      } finally {
        await client.disconnect();
      }

      if (!_actionOk(actionResult) && legacyFallback != null) {
        _log('$actionLabel flutter_skill failed, trying legacy');
        driver = 'legacy_fallback';
        final legacy = await legacyFallback();
        actionResult = {
          'success': legacy['ok'] == true || legacy['success'] == true,
          'flutterSkill': actionResult,
          'legacy': legacy,
        };
      } else if (_actionOk(actionResult)) {
        await bridge.waitStable(waitStableMs: wait);
      }
    } else if (legacyFallback != null) {
      driver = 'legacy';
      final legacy = await legacyFallback();
      actionResult = {
        'success': legacy['ok'] == true || legacy['success'] == true,
        'legacy': legacy,
      };
    } else {
      actionResult = {
        'success': false,
        'error': 'no vmServiceUri and no legacy fallback',
      };
    }

    final afterRes = await bridge.snapshot();
    if (afterRes['ok'] != true) {
      return {
        'ok': false,
        'error': 'after snapshot failed',
        'detail': afterRes,
      };
    }
    final after =
        (afterRes['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};

    final diff = computePerfDiff(
      before: before,
      after: after,
      durationMs: DateTime.now().difference(t0).inMilliseconds,
    );

    final ok = _actionOk(actionResult);
    final alerts = reports.evaluateDiff(
      diff,
      stepId: stepId,
      action: actionLabel,
    );
    for (final a in alerts) {
      session.addAlert(a);
    }

    final step = {
      'stepId': stepId,
      'action': action,
      'ok': ok,
      'driver': driver,
      'actionResult': actionResult,
      'diff': diff,
      'alerts': alerts,
      'at': DateTime.now().toIso8601String(),
      ...?extraStepFields,
    };
    session.addStep(step);
    _log('end $actionLabel ok=$ok alerts=${alerts.length}');
    return step;
  }

  bool _actionOk(Map<String, dynamic> result) {
    if (result['success'] == true || result['ok'] == true) return true;
    final nested = result['result'];
    if (nested is Map && (nested['success'] == true || nested['ok'] == true)) {
      return true;
    }
    return false;
  }
}
