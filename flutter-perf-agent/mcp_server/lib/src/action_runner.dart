import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'bridge_client.dart';
import 'cold_start.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'flutter_skill_vm_client.dart';
import 'perf_diff.dart';
import 'report_writer.dart';

typedef SkillAction = Future<Map<String, dynamic>> Function(
  FlutterSkillClient client,
);

/// Shared before → action → settle → after → Sleuth/RSS diff (+ screenshot).
///
/// Steps are **route chapters**. Same-route actions append a linear [events]
/// timeline (screenshot → action → network → navigate). A route change opens
/// a new chapter for the landing page.
class ActionRunner {
  ActionRunner({
    required this.config,
    required this.bridge,
    required this.reports,
    required this.session,
    required Future<FlutterSkillClient?> Function() ensureSkillClient,
    required int Function() nextStepId,
  })  : _ensureSkillClient = ensureSkillClient,
        _nextStepId = nextStepId;

  final PerfAgentConfig config;
  final BridgeClient bridge;
  final ReportWriter reports;
  final PerfSession session;
  final Future<FlutterSkillClient?> Function() _ensureSkillClient;
  final int Function() _nextStepId;

  void _log(String msg) {
    if (config.debugLog) {
      io.stderr.writeln('[perf-agent] $msg');
    }
  }

  /// Record the page currently on screen (used at session start).
  Future<StepResult> observeRoute({String cause = 'observe'}) async {
    final route = await _fetchRoute() ?? 'unknown';
    final stepId = 'step_${_nextStepId()}';
    _log('observe route $route ($stepId)');

    final client = await _ensureSkillClient();
    final shot = await _maybeShot(client, stepId, 'e0', retryOnEmpty: true);
    final now = DateTime.now().toIso8601String();
    final events = <StepEvent>[
      if (shot.path != null)
        StepEvent(
          type: 'screenshot',
          at: now,
          label: '落页截图',
          screenshotPath: shot.path,
          screenshotDataUri: shot.dataUri,
        ),
      StepEvent(type: 'action', at: now, label: cause),
    ];

    final step = StepResult(
      stepId: stepId,
      action: 'route:$route',
      route: route,
      ok: true,
      driver: 'route_observe',
      events: events,
      screenshotPath: shot.path,
      screenshotDataUri: shot.dataUri,
      at: now,
      extra: {
        'cause': cause,
        'actions': <String>[cause],
        'routeChanged': true,
      },
    );
    session.addStep(step);
    return step;
  }

  /// First report step: cold start (TTFF) + first-route screenshot.
  Future<StepResult> recordColdStart({
    bool? relaunch,
    Future<void> Function()? onAfterRelaunch,
  }) async {
    final doRelaunch = relaunch ?? config.coldStartRelaunch;
    int? processLaunchMs;
    if (doRelaunch) {
      final launcher = ColdStartLauncher(
        config: config,
        bridge: bridge,
        log: _log,
      );
      processLaunchMs = await launcher.relaunchAndWait();
      await onAfterRelaunch?.call();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final startup = await _awaitStartupMetrics();
    final route = await _fetchRoute() ?? 'unknown';
    final stepId = 'step_${_nextStepId()}';
    _log(
      'cold_start route=$route ttff=${startup?.ttffMs} '
      'launchMs=$processLaunchMs ($stepId)',
    );

    await bridge.waitStable(waitStableMs: config.waitStableMs);

    final client = await _ensureSkillClient();
    final shot = await _maybeShot(client, stepId, 'e1', retryOnEmpty: true);

    final ttff = startup?.ttffMs;
    final alerts = <AlertItem>[];
    if (ttff != null && ttff >= config.ttffWarningMs) {
      final alert = AlertItem(
        type: 'slow_cold_start',
        stepId: stepId,
        action: 'cold_start',
        message:
            'TTFF ${ttff.toStringAsFixed(0)} ms ≥ 阈值 ${config.ttffWarningMs} ms',
        value: ttff,
        threshold: config.ttffWarningMs,
      );
      alerts.add(alert);
      session.addAlert(alert);
    }

    final phases = buildColdStartPhases(startup?.metrics);
    final now = DateTime.now().toIso8601String();
    final events = <StepEvent>[
      StepEvent(
        type: 'cold_start',
        at: now,
        label: '冷启动（方案 A · 引擎/Dart）',
        detail: {
          if (ttff != null) 'ttffMs': ttff,
          if (startup?.ttiMs != null) 'ttiMs': startup!.ttiMs,
          if (startup?.engineTtffMs != null)
            'engineTtffMs': startup!.engineTtffMs,
          if (startup?.frameworkInitMs != null)
            'frameworkInitMs': startup!.frameworkInitMs,
          if (startup?.metrics != null) 'startup': startup!.metrics,
          if (phases.isNotEmpty) 'phases': phases,
          // processLaunchMs is scheme B; keep for对照 only.
          if (processLaunchMs != null) 'processLaunchMs': processLaunchMs,
        },
      ),
      if (shot.path != null)
        StepEvent(
          type: 'screenshot',
          at: now,
          label: '首屏截图',
          screenshotPath: shot.path,
          screenshotDataUri: shot.dataUri,
        ),
    ];

    // Scheme A: primary duration is TTFF (not process launch).
    final durationMs = ttff?.round() ?? processLaunchMs;
    final step = StepResult(
      stepId: stepId,
      action: 'cold_start',
      route: route,
      ok: true,
      driver: doRelaunch ? 'cold_start_relaunch' : 'cold_start',
      diff: durationMs == null
          ? null
          : PerfDiffData(
              durationMs: durationMs,
              memoryDeltaBytes: 0,
              memoryDeltaMb: 0,
              issuesBefore: const [],
              issuesAfter: const [],
            ),
      events: events,
      screenshotPath: shot.path,
      screenshotDataUri: shot.dataUri,
      alerts: alerts,
      at: now,
      extra: {
        'kind': 'cold_start',
        'scheme': 'A',
        'noMerge': true,
        'cause': 'cold_start',
        'actions': <String>['cold_start'],
        'routeChanged': true,
        if (processLaunchMs != null) 'processLaunchMs': processLaunchMs,
        if (startup?.metrics != null) 'startup': startup!.metrics,
        if (phases.isNotEmpty) 'startupPhases': phases,
        if (ttff != null) 'ttffMs': ttff,
        if (startup?.ttiMs != null) 'ttiMs': startup!.ttiMs,
        if (startup?.engineTtffMs != null) 'engineTtffMs': startup!.engineTtffMs,
        if (startup?.frameworkInitMs != null)
          'frameworkInitMs': startup!.frameworkInitMs,
      },
    );
    session.addStep(step);
    await _mirrorToSdkJournal(step);
    return step;
  }

  Future<StartupMetricsData?> _awaitStartupMetrics() async {
    // TTFF usually lands first; Pre-Dart / Engine TTFF need VM enrichment.
    final ttffDeadline = DateTime.now().add(const Duration(seconds: 8));
    final enrichDeadline = DateTime.now().add(const Duration(seconds: 14));
    StartupMetricsData? last;
    while (DateTime.now().isBefore(enrichDeadline)) {
      try {
        final res = await bridge.sleuthStartup();
        if (res.isOk && res.data != null) {
          last = res.data;
          final m = last!.metrics;
          final hasTtff = last.ttffMs != null;
          final hasPreDart = m?['preDartOverheadMs'] != null ||
              m?['engineTtffMs'] != null ||
              m?['engineEnterUs'] != null;
          if (hasTtff && hasPreDart) return last;
          // Keep TTFF once available; only wait longer for enrichment.
          if (hasTtff && DateTime.now().isAfter(ttffDeadline)) return last;
        }
      } catch (e) {
        _log('sleuthStartup: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return last;
  }

  Future<StepResult> run({
    required String action,
    required String actionLabel,
    required SkillAction skillAction,
    Map<String, dynamic>? extraStepFields,
    int? waitStableMs,
    int? extraSettleMs,
    bool expectNavigation = false,
    Future<ApiResponse<TapLegacyData>> Function()? legacyFallback,
  }) async {
    final wait = waitStableMs ?? config.waitStableMs;
    final t0 = DateTime.now();
    final networkSince = t0.toIso8601String();
    final routeBefore = await _fetchRoute() ?? 'unknown';
    _log('begin $actionLabel (route=$routeBefore)');

    final client = await _ensureSkillClient();

    // Open or reuse chapter for the route where the action starts.
    var chapter = _openChapterFor(routeBefore);
    if (chapter == null) {
      final stepId = 'step_${_nextStepId()}';
      final pre = await _maybeShot(client, stepId, 'pre', retryOnEmpty: true);
      final now = DateTime.now().toIso8601String();
      chapter = StepResult(
        stepId: stepId,
        action: 'route:$routeBefore',
        route: routeBefore,
        ok: true,
        driver: 'flutter_skill',
        events: [
          if (pre.path != null)
            StepEvent(
              type: 'screenshot',
              at: now,
              label: '操作前截图',
              screenshotPath: pre.path,
              screenshotDataUri: pre.dataUri,
            ),
        ],
        screenshotPath: pre.path,
        screenshotDataUri: pre.dataUri,
        at: now,
        extra: {
          'cause': actionLabel,
          'actions': <String>[],
          'routeChanged': false,
        },
      );
      session.addStep(chapter);
      _log('open chapter $routeBefore ($stepId)');
    }

    final beforeRes = await bridge.snapshot();
    if (!beforeRes.isOk || beforeRes.data == null) {
      return _failChapter(
        chapter,
        actionLabel: actionLabel,
        error: 'before snapshot failed: ${beforeRes.msg}',
        extraStepFields: extraStepFields,
      );
    }
    final before = beforeRes.data!.snapshot;

    ActionResult actionResult;
    var driver = 'flutter_skill';

    if (client != null) {
      await bridge.mcpGuard(active: true);
      try {
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
          final legacyOk =
              legacy.isOk && (legacy.data?.action.success ?? false);
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
          // Single post-action wait (stable + settle). Nav land wait is
          // applied once below if the route actually changes — don't stack.
          final settle =
              wait + (extraSettleMs ?? 0) + config.postActionSettleMs;
          if (settle > 0) {
            await bridge.waitStable(waitStableMs: settle);
          }
        }
      } finally {
        await bridge.mcpGuard(active: false);
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

    // Gesture/action time = window start (before skill tap), not finalize time.
    // Otherwise network startedAt sorts before the click in the timeline.
    final actionAt = networkSince;
    final wantNav = expectNavigation || (extraSettleMs ?? 0) > 0;
    final routeAfter = await _awaitRoute(
      previous: routeBefore,
      expectChange: wantNav && actionResult.success,
    );
    final routeChanged = routeAfter != null &&
        routeAfter.isNotEmpty &&
        routeAfter != routeBefore;

    if (routeChanged && actionResult.success) {
      // Extra land settle only (post-action wait already ran above).
      final landSettle = config.postActionSettleMs > 0
          ? config.postActionSettleMs
          : 120;
      await bridge.waitStable(waitStableMs: landSettle);
    }

    // Parallel: after snapshot + sleuth issues + network (was sequential).
    final afterFut = bridge.snapshot();
    final issuesFut = bridge.sleuthIssues(limit: 30);
    final netFut = bridge.networkRequests(sinceIso: networkSince, limit: 100);
    final afterRes = await afterFut;
    if (!afterRes.isOk || afterRes.data == null) {
      return _failChapter(
        chapter,
        actionLabel: actionLabel,
        error: 'after snapshot failed: ${afterRes.msg}',
        actionResult: actionResult,
        driver: driver,
        extraStepFields: extraStepFields,
      );
    }
    final after = afterRes.data!.snapshot;

    // Chapter-scoped memory window: first action's before → latest after.
    final baselineBefore = chapter.diff?.before ?? before;
    final diff = computePerfDiff(
      before: baselineBefore,
      after: after,
      durationMs: DateTime.now().difference(t0).inMilliseconds,
    );
    final ok = actionResult.success;

    SleuthIssuesData? sleuthIssues;
    try {
      final issuesRes = await issuesFut;
      if (issuesRes.isOk) sleuthIssues = issuesRes.data;
    } catch (e) {
      _log('sleuth issues fetch failed: $e');
    }

    var networkRequests = <NetworkRequest>[];
    try {
      final netRes = await netFut;
      if (netRes.isOk && netRes.data != null) {
        networkRequests = netRes.data!.requests;
        _log('network ${networkRequests.length} req since $networkSince');
      }
    } catch (e) {
      _log('network fetch failed: $e');
    }

    final stepId = chapter.stepId;
    final evaluated = reports.evaluateDiff(
      diff,
      stepId: stepId,
      action: '$routeBefore · $actionLabel',
      sleuthIssues: sleuthIssues,
    );
    // memory_increase is chapter-stateful: replace per stepId (align with final diff).
    final memAlerts =
        evaluated.where((a) => a.type == 'memory_increase').toList();
    final otherAlerts =
        evaluated.where((a) => a.type != 'memory_increase').toList();
    session.removeAlertsWhere(
      (a) => a.stepId == stepId && a.type == 'memory_increase',
    );
    for (final a in memAlerts) {
      session.addAlert(a);
    }
    for (final a in otherAlerts) {
      session.addAlert(a);
    }
    final alerts = <AlertItem>[...memAlerts, ...otherAlerts];

    // Split network: stamp-matching source route stays on this chapter.
    final sourceNet = <NetworkRequest>[];
    final destNet = <NetworkRequest>[];
    for (final r in networkRequests) {
      if (routeChanged && _routeMatches(r.route, routeAfter)) {
        destNet.add(r);
      } else {
        sourceNet.add(r);
      }
    }

    final newEvents = <StepEvent>[
      StepEvent(
        type: 'action',
        at: actionAt,
        label: actionLabel,
        ok: ok,
        detail: {
          'action': action,
          ...?extraStepFields,
          if (actionResult.error != null) 'error': actionResult.error,
        },
      ),
      for (final r in sourceNet) _networkEvent(r),
    ];

    if (routeChanged) {
      String kind = 'route_change';
      Map<String, dynamic>? leakJson;
      String? metaFrom;
      String? metaTo;
      try {
        final meta = await bridge.appRoute();
        if (meta.isOk && meta.data != null) {
          metaFrom = meta.data!.from;
          metaTo = meta.data!.to;
          final k = meta.data!.transitionKind;
          // Only trust Bridge last-kind when it describes this edge; otherwise
          // Tab switches inherited a stale GetX `remove` from offAll.
          if (k != null &&
              k.isNotEmpty &&
              _edgeMatches(metaFrom, metaTo, routeBefore, routeAfter)) {
            kind = k;
          }
        }
      } catch (_) {}
      kind = _inferTransitionKind(
        routeBefore: routeBefore,
        routeAfter: routeAfter,
        metaKind: kind,
      );

      if (_isClosingTransition(kind, routeBefore, routeAfter)) {
        try {
          final probe = await bridge.transitionLeakProbe(
            route: routeBefore,
            settleMs: config.transitionSettleMs,
          );
          if (probe.isOk && probe.data != null) {
            leakJson = Map<String, dynamic>.from(probe.data!);
            final alive = (leakJson['alive'] as List?) ?? const [];
            final sleuthHits =
                (leakJson['sleuthHits'] as List?) ?? const [];
            final multi = leakJson['multiRoundConfirmed'] == true;
            final hasWeak = alive.isNotEmpty;
            final hasSleuth = sleuthHits.isNotEmpty;

            if (config.leakVmDeepProbe && hasWeak) {
              leakJson = await _attachVmDeep(leakJson);
            }

            final shouldAlert = _shouldAlertLeak(
              hasWeak: hasWeak,
              hasSleuth: hasSleuth,
              multiRoundConfirmed: multi,
            );

            if (shouldAlert) {
              final parts = <String>[];
              if (alive.isNotEmpty) {
                final names = alive
                    .map((e) => e is Map ? e['name'] : e)
                    .join(', ');
                parts.add('仍可达: $names（WeakRef）');
              }
              if (sleuthHits.isNotEmpty) {
                final titles = sleuthHits
                    .map((e) => e is Map
                        ? (e['title'] ?? e['stableId'] ?? '?')
                        : e)
                    .join(', ');
                parts.add('Sleuth: $titles');
              }
              final counts = (leakJson['aliveCounts'] as List?) ?? const [];
              final multiNote = multi && counts.isNotEmpty
                  ? '；多轮确认：同路由 ${counts.length} 次进出存活数 '
                      '[${counts.join('→')}]'
                  : '';
              var evidence = leakJson['evidence']?.toString() ?? '';
              if (leakJson['vmDeep'] is Map &&
                  (leakJson['vmDeep'] as Map)['ok'] == true) {
                evidence = evidence.isEmpty || evidence == 'none'
                    ? 'vm_deep'
                    : '$evidence+vm_deep';
                leakJson['evidence'] = evidence;
              }
              final leakAlert = AlertItem(
                type: 'transition_memory_leak',
                stepId: chapter.stepId,
                action: actionLabel,
                message:
                    'pop $routeBefore 后 ${parts.join('；')}$multiNote'
                    '${evidence.isNotEmpty ? ' · evidence=$evidence' : ''}',
                value: leakJson,
              );
              alerts.add(leakAlert);
              session.addAlert(leakAlert);
            }
            final rssDelta = (leakJson['rssDeltaMb'] as num?)?.toDouble();
            if (config.alertOnRssRetain &&
                rssDelta != null &&
                rssDelta >= config.leakRssRetainMb) {
              final rssAlert = AlertItem(
                type: 'transition_memory_retain_rss',
                stepId: chapter.stepId,
                action: actionLabel,
                message:
                    'pop $routeBefore 后 RSS 辅证滞留 ${rssDelta.toStringAsFixed(2)} MB',
                value: rssDelta,
                threshold: config.leakRssRetainMb,
              );
              alerts.add(rssAlert);
              session.addAlert(rssAlert);
            }
          }
        } catch (e) {
          _log('leak probe failed: $e');
        }
      }

      final p90 = diff.p90FrameMsAfter;
      if (p90 != null && p90 > config.maxFrameCostMs) {
        final jankAlert = AlertItem(
          type: 'transition_jank',
          stepId: chapter.stepId,
          action: actionLabel,
          message:
              '转场窗 P90 ${p90.toStringAsFixed(1)}ms > ${config.maxFrameCostMs}ms',
          value: p90,
          threshold: config.maxFrameCostMs,
        );
        alerts.add(jankAlert);
        session.addAlert(jankAlert);
      } else if ((diff.jankDelta ?? 0) > 0) {
        final jankAlert = AlertItem(
          type: 'transition_jank',
          stepId: chapter.stepId,
          action: actionLabel,
          message: '转场窗新增 Jank ${diff.jankDelta} 次',
          value: diff.jankDelta,
        );
        alerts.add(jankAlert);
        session.addAlert(jankAlert);
      }

      newEvents.add(
        StepEvent(
          type: 'navigate',
          at: DateTime.now().toIso8601String(),
          label: '$routeBefore → $routeAfter',
          detail: {
            'from': routeBefore,
            'to': routeAfter,
            'transitionKind': kind,
            if (leakJson != null) 'leak': leakJson,
          },
        ),
      );
    } else if (config.captureScreenshots && client != null) {
      final idx = chapter.events.length + newEvents.length;
      final shot = await _maybeShot(
        client,
        chapter.stepId,
        'e$idx',
        retryOnEmpty: wantNav,
      );
      if (shot.path != null) {
        newEvents.add(
          StepEvent(
            type: 'screenshot',
            at: DateTime.now().toIso8601String(),
            label: '操作后截图',
            screenshotPath: shot.path,
            screenshotDataUri: shot.dataUri,
          ),
        );
      }
    }

    final actions = [
      ..._asStringList(chapter.extra['actions']),
      actionLabel,
    ];
    StepEvent? coverShot;
    for (final e in newEvents.reversed) {
      if (e.type == 'screenshot') {
        coverShot = e;
        break;
      }
    }

    final keptChapterAlerts = chapter.alerts
        .where((a) => a.type != 'memory_increase')
        .toList();
    final updated = chapter.copyWith(
      ok: chapter.ok && ok,
      driver: driver,
      actionResult: actionResult,
      diff: diff,
      sleuthIssues: sleuthIssues,
      networkRequests: _mergeNetwork(chapter.networkRequests, sourceNet),
      events: [...chapter.events, ...newEvents],
      alerts: [...keptChapterAlerts, ...alerts],
      screenshotPath: coverShot?.screenshotPath ?? chapter.screenshotPath,
      screenshotDataUri:
          coverShot?.screenshotDataUri ?? chapter.screenshotDataUri,
      at: DateTime.now().toIso8601String(),
      extra: {
        ...chapter.extra,
        'cause': actionLabel,
        'actions': actions,
        'routeBefore': routeBefore,
        'routeChanged': routeChanged,
        'lastAction': action,
        'rssBaselineBytes':
            chapter.extra['rssBaselineBytes'] ?? baselineBefore.rssBytes,
        ...?extraStepFields,
      },
    );
    session.replaceLastStep(updated);
    _log(
      'chapter $routeBefore +$actionLabel events=${updated.events.length} '
      'net=${sourceNet.length} nav=$routeChanged',
    );

    // Mirror full chapter into App SDK journal (same schema as manual).
    await _mirrorToSdkJournal(updated);

    if (!routeChanged) {
      return updated;
    }

    // Landing chapter for destination route.
    final landId = 'step_${_nextStepId()}';
    final landShot = await _maybeShot(
      client,
      landId,
      'land',
      retryOnEmpty: true,
    );
    final landAt = DateTime.now().toIso8601String();
    final landEvents = <StepEvent>[
      if (landShot.path != null)
        StepEvent(
          type: 'screenshot',
          at: landAt,
          label: '落页截图',
          screenshotPath: landShot.path,
          screenshotDataUri: landShot.dataUri,
        ),
      for (final r in destNet) _networkEvent(r),
    ];
    final land = StepResult(
      stepId: landId,
      action: 'route:$routeAfter',
      route: routeAfter,
      ok: true,
      driver: driver,
      networkRequests: destNet,
      events: landEvents,
      screenshotPath: landShot.path,
      screenshotDataUri: landShot.dataUri,
      at: landAt,
      extra: {
        'cause': 'navigate_from:$actionLabel',
        'actions': <String>['navigate_from:$actionLabel'],
        'routeBefore': routeBefore,
        'routeChanged': true,
        'landedFrom': routeBefore,
      },
    );
    session.addStep(land);
    await _mirrorToSdkJournal(land);
    _log('land chapter $routeAfter ($landId) net=${destNet.length}');
    return land;
  }

  bool _isSealed(StepResult s) =>
      s.extra['noMerge'] == true ||
      s.extra['kind'] == 'cold_start' ||
      s.action == 'cold_start';

  /// Last open chapter for [route], or null to open a new one.
  StepResult? _openChapterFor(String route) {
    if (session.steps.isEmpty) return null;
    final last = session.steps.last;
    if (_isSealed(last)) return null;
    if (last.route != route) return null;
    // Already navigated away marker — still same route means stay open.
    return last;
  }

  static String _routeShell(String? route) {
    if (route == null || route.isEmpty) return '';
    return route.split('#').first;
  }

  static bool _isTabOnly(String? from, String? to) {
    if (from == null || to == null || from == to) return false;
    final a = _routeShell(from);
    final b = _routeShell(to);
    return a.isNotEmpty && a == b;
  }

  static bool _sameShellEndpoint(String? a, String? b) {
    if (a == null || b == null) return a == b;
    return a == b || _routeShell(a) == _routeShell(b);
  }

  static bool _edgeMatches(
    String? metaFrom,
    String? metaTo,
    String routeBefore,
    String routeAfter,
  ) {
    return _sameShellEndpoint(metaFrom, routeBefore) &&
        _sameShellEndpoint(metaTo, routeAfter);
  }

  static String _inferTransitionKind({
    required String routeBefore,
    required String routeAfter,
    required String metaKind,
  }) {
    if (_isTabOnly(routeBefore, routeAfter)) return 'tab_change';
    if (metaKind != 'route_change' && metaKind.isNotEmpty) return metaKind;
    return 'route_change';
  }

  static bool _isClosingTransition(
    String kind,
    String routeBefore,
    String routeAfter,
  ) {
    if (_isTabOnly(routeBefore, routeAfter) || kind == 'tab_change') {
      return false;
    }
    if (kind == 'pop' || kind == 'remove') {
      // Real leave: shells must differ (GetX offAll remove of /login, etc.).
      return _routeShell(routeBefore) != _routeShell(routeAfter);
    }
    if (!kind.startsWith('modal_')) return false;
    return routeBefore.startsWith('#modal/') ||
        routeBefore.contains('#modal/');
  }

  bool _shouldAlertLeak({
    required bool hasWeak,
    required bool hasSleuth,
    required bool multiRoundConfirmed,
  }) {
    if (hasWeak) {
      if (!config.alertOnWeakRef) return false;
      if (config.requireMultiRound && !multiRoundConfirmed) return false;
      return true;
    }
    if (hasSleuth) return config.alertOnSleuthOnly;
    return false;
  }

  Future<Map<String, dynamic>> _attachVmDeep(
    Map<String, dynamic> leakJson,
  ) async {
    try {
      final client = await _ensureSkillClient();
      if (client is! FlutterSkillVmClient) {
        leakJson['vmDeep'] = {
          'skipped': true,
          'reason': 'no_vm_client',
        };
        return leakJson;
      }
      final note = await client.collectLeakVmDeepNote();
      leakJson['vmDeep'] = note;
      if (note['ok'] == true) {
        final ev = leakJson['evidence']?.toString() ?? '';
        leakJson['evidence'] =
            (ev.isEmpty || ev == 'none') ? 'vm_deep' : '$ev+vm_deep';
      }
    } catch (e) {
      leakJson['vmDeep'] = {'skipped': true, 'reason': '$e'};
    }
    return leakJson;
  }

  Future<StepResult> _failChapter(
    StepResult chapter, {
    required String actionLabel,
    required String error,
    ActionResult? actionResult,
    String driver = 'none',
    Map<String, dynamic>? extraStepFields,
  }) {
    final now = DateTime.now().toIso8601String();
    final updated = chapter.copyWith(
      ok: false,
      driver: driver,
      actionResult: actionResult ??
          ActionResult(success: false, driver: driver, error: error),
      events: [
        ...chapter.events,
        StepEvent(
          type: 'action',
          at: now,
          label: actionLabel,
          ok: false,
          detail: {'error': error, ...?extraStepFields},
        ),
      ],
      at: now,
      extra: {
        ...chapter.extra,
        'cause': actionLabel,
        'actions': [..._asStringList(chapter.extra['actions']), actionLabel],
        ...?extraStepFields,
      },
    );
    session.replaceLastStep(updated);
    return Future.value(updated);
  }

  Future<String?> _fetchRoute() async {
    try {
      final res = await bridge.appRoute();
      if (res.isOk && res.data != null) {
        final r = res.data!.route.trim();
        if (r.isNotEmpty) return r;
      }
    } catch (e) {
      _log('appRoute failed: $e');
    }
    return null;
  }

  Future<String?> _awaitRoute({
    required String? previous,
    required bool expectChange,
  }) async {
    var route = await _fetchRoute();
    if (!expectChange) return route;
    for (var i = 0; i < 15; i++) {
      if (route != null && previous != null && route != previous) {
        return route;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      route = await _fetchRoute();
    }
    return route;
  }

  Future<({String? path, String? dataUri})> _maybeShot(
    FlutterSkillClient? client,
    String stepId,
    String suffix, {
    bool retryOnEmpty = false,
  }) async {
    if (!config.captureScreenshots || client == null) {
      return (path: null, dataUri: null);
    }
    try {
      await client.ensureConnected();
      var b64 = await client.screenshotBase64();
      if ((b64 == null || b64.isEmpty) && retryOnEmpty) {
        _log('screenshot empty, retry after settle');
        await bridge.waitStable(waitStableMs: config.waitStableMs);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        b64 = await client.screenshotBase64();
      }
      if (b64 != null && b64.isNotEmpty) {
        final path = await _saveScreenshot('${stepId}_$suffix', b64);
        _log('screenshot saved $path');
        return (path: path, dataUri: 'data:image/png;base64,$b64');
      }
    } catch (e) {
      _log('screenshot failed: $e');
    }
    return (path: null, dataUri: null);
  }

  Future<String> _saveScreenshot(String name, String base64) async {
    final dir = io.Directory(
      p.join(config.reportsDir, 'screenshots', session.sessionId),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final path = p.join(dir.path, '$name.png');
    await io.File(path).writeAsBytes(base64Decode(base64));
    return path;
  }

  /// Upsert full route-chapter into App SDK journal (paths only, no data URI).
  Future<void> _mirrorToSdkJournal(StepResult step) async {
    try {
      final extra = Map<String, dynamic>.from(step.extra);
      extra.putIfAbsent('source', () => 'mcp');
      final payload = step
          .copyWith(extra: extra)
          .toJson(includeScreenshotDataUri: false);
      await bridge.appendStep(
        step: payload,
        sessionId: session.sessionId,
        testName: session.testName,
      );
    } catch (e) {
      _log('mirror to sdk journal failed: $e');
    }
  }

  static bool _routeMatches(String? reqRoute, String? stepRoute) {
    if (reqRoute == null || stepRoute == null) return false;
    final a = reqRoute.trim();
    final b = stepRoute.trim();
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (!a.contains('#') && b.startsWith('$a#')) return true;
    if (!b.contains('#') && a.startsWith('$b#')) return true;
    return a.split('#').first == b.split('#').first;
  }

  static String _shortUrl(String url) {
    try {
      final u = Uri.parse(url);
      return u.path.isEmpty ? url : u.path;
    } catch (_) {
      return url;
    }
  }

  static StepEvent _networkEvent(NetworkRequest r) => StepEvent(
        type: 'network',
        at: r.startedAt,
        label: '${r.method} ${_shortUrl(r.url)}',
        ok: r.statusCode > 0 && r.statusCode < 400,
        // Full capture so the timeline can expand headers/bodies inline.
        detail: r.toJson(),
      );

  static List<String> _asStringList(Object? raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).toList();
  }

  static List<NetworkRequest> _mergeNetwork(
    List<NetworkRequest> a,
    List<NetworkRequest> b,
  ) {
    if (b.isEmpty) return a;
    if (a.isEmpty) return b;
    final keys = <String>{
      for (final r in a) '${r.startedAt}|${r.method}|${r.url}|${r.statusCode}',
    };
    final out = [...a];
    for (final r in b) {
      final k = '${r.startedAt}|${r.method}|${r.url}|${r.statusCode}';
      if (keys.add(k)) out.add(r);
    }
    return out;
  }
}
