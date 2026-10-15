import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'perf_diff.dart';
import 'report_writer.dart';

typedef SkillAction = Future<Map<String, dynamic>> Function(
  FlutterSkillVmClient client,
);

/// Shared before → action → settle → after → diff (+ optional screenshot).
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

  Future<Map<String, dynamic>> run({
    required String action,
    required String actionLabel,
    required SkillAction skillAction,
    Map<String, dynamic>? extraStepFields,
    int? waitStableMs,
    /// Extra settle after action (e.g. navigation after login).
    int? extraSettleMs,
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
    final client = await _ensureSkillClient();

    if (client != null) {
      try {
        await client.ensureConnected();
        actionResult = await skillAction(client);
      } catch (e) {
        actionResult = {
          'success': false,
          'error': 'flutter_skill $action failed: $e',
          'vmServiceUri': client.wsUri,
        };
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
        final settle = (extraSettleMs ?? 0) + config.postActionSettleMs;
        if (settle > 0) {
          await Future<void>.delayed(Duration(milliseconds: settle));
        }
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

    final step = {
      'stepId': stepId,
      'action': action,
      'ok': ok,
      'driver': driver,
      'actionResult': actionResult,
      'diff': diff,
      'alerts': alerts,
      if (screenshotPath != null) 'screenshotPath': screenshotPath,
      // Keep data URI out of JSON dump size — HTML builder reads file if needed.
      if (screenshotDataUri != null) 'screenshotDataUri': screenshotDataUri,
      'at': DateTime.now().toIso8601String(),
      ...?extraStepFields,
    };
    session.addStep(step);
    _log('end $actionLabel ok=$ok alerts=${alerts.length}');

    // Strip huge data URI from returned MCP payload (still in session for HTML).
    final forMcp = Map<String, dynamic>.from(step)
      ..remove('screenshotDataUri');
    return forMcp;
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

  bool _actionOk(Map<String, dynamic> result) {
    if (result['success'] == true || result['ok'] == true) return true;
    final nested = result['result'];
    if (nested is Map && (nested['success'] == true || nested['ok'] == true)) {
      return true;
    }
    return false;
  }
}
