import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'network_capture.dart';
import 'perf_snapshot.dart';
import 'sleuth_transition_binder.dart';

class _Tracked {
  _Tracked({
    required this.name,
    required this.route,
    required this.ref,
    required this.registeredAt,
  });

  final String name;
  final String route;
  final WeakReference<Object> ref;
  final DateTime registeredAt;
}

/// Result of a post-pop leak probe (no forced GC).
class TransitionLeakProbe {
  const TransitionLeakProbe({
    required this.route,
    required this.alive,
    required this.rssBeforeMb,
    required this.rssAfterMb,
    required this.settleMs,
    required this.roundIndex,
    required this.aliveCounts,
    required this.multiRoundConfirmed,
    this.sleuthHits = const [],
  });

  final String route;
  final List<Map<String, dynamic>> alive;
  final double? rssBeforeMb;
  final double? rssAfterMb;
  final int settleMs;

  /// 1-based pop round for this route in the current session.
  final int roundIndex;

  /// Historical aliveCount after each pop of this route (oldest → newest).
  final List<int> aliveCounts;

  /// True when last [leakConfirmRounds] counts are all > 0 and non-decreasing.
  final bool multiRoundConfirmed;

  /// Allowlisted Sleuth issues new since push of this route.
  final List<Map<String, dynamic>> sleuthHits;

  bool get hasWeakRefLeak => alive.isNotEmpty;

  bool get hasSleuthLeak => sleuthHits.isNotEmpty;

  bool get hasLeak => hasWeakRefLeak || hasSleuthLeak;

  double? get rssDeltaMb {
    if (rssBeforeMb == null || rssAfterMb == null) return null;
    return double.parse((rssAfterMb! - rssBeforeMb!).toStringAsFixed(3));
  }

  String get multiRoundSummary {
    if (aliveCounts.isEmpty) return '';
    final series = aliveCounts.join('→');
    return '同路由 ${aliveCounts.length} 次进出存活数 [$series]';
  }

  /// weak_ref_multi | weak_ref | sleuth | weak_ref+sleuth | weak_ref_multi+sleuth
  String get evidence {
    final wr = hasWeakRefLeak
        ? (multiRoundConfirmed ? 'weak_ref_multi' : 'weak_ref')
        : null;
    final sl = hasSleuthLeak ? 'sleuth' : null;
    if (wr != null && sl != null) return '$wr+$sl';
    if (wr != null) return wr;
    if (sl != null) return sl;
    return 'none';
  }

  Map<String, dynamic> toJson() => {
        'route': route,
        'aliveCount': alive.length,
        'alive': alive,
        'rssBeforeMb': rssBeforeMb,
        'rssAfterMb': rssAfterMb,
        'rssDeltaMb': rssDeltaMb,
        'settleMs': settleMs,
        'roundIndex': roundIndex,
        'aliveCounts': aliveCounts,
        'multiRoundConfirmed': multiRoundConfirmed,
        'sleuthHits': sleuthHits,
        'evidence': evidence,
      };
}

/// Registers objects per route and checks WeakRef liveness after pop.
///
/// Does **not** call VM forced GC — still-reachable objects are leaks.
/// V2: keeps per-route [aliveCounts] history for multi-round confirmation.
/// V2.1: merges Sleuth transition-window hits ([SleuthTransitionBinder]).
class TransitionLeakTracker {
  TransitionLeakTracker._();
  static final TransitionLeakTracker instance = TransitionLeakTracker._();

  /// Master switch (= PRD `leakTrackEnabled`).
  bool enabled = true;

  /// Wait after pop before WeakRef check (= PRD `transitionSettleMs`).
  int settleMs = 1500;

  /// Consecutive pops needed for stair / hold confirmation (PRD default 2).
  int leakConfirmRounds = 2;

  /// RSS retain (MB) for auxiliary alert only.
  double rssRetainMb = 5;

  final List<_Tracked> _tracked = [];
  final Map<String, double> _rssAtPush = {};

  /// routeKey → aliveCount after each pop (session-scoped).
  final Map<String, List<int>> _aliveHistory = {};

  void clear() {
    _tracked.clear();
    _rssAtPush.clear();
    _aliveHistory.clear();
  }

  /// Apply config from [PerfAgent.ensureInitialized] / MCP session start.
  void configure({
    bool? enabled,
    int? settleMs,
    int? leakConfirmRounds,
    double? rssRetainMb,
    bool? sleuthBindEnabled,
  }) {
    if (enabled != null) this.enabled = enabled;
    if (settleMs != null && settleMs >= 0) this.settleMs = settleMs;
    if (leakConfirmRounds != null && leakConfirmRounds >= 1) {
      this.leakConfirmRounds = leakConfirmRounds;
    }
    if (rssRetainMb != null && rssRetainMb >= 0) {
      this.rssRetainMb = rssRetainMb;
    }
    if (sleuthBindEnabled != null) {
      SleuthTransitionBinder.instance.enabled = sleuthBindEnabled;
    }
  }

  /// Register [resource] as owned by [route] (defaults to current route).
  void track(Object resource, {String? name, String? route}) {
    if (!enabled || kReleaseMode) return;
    final r = route ?? PerfNetworkCapture.currentRoute() ?? '(unknown)';
    final n = name ?? resource.runtimeType.toString();
    // Only dedupe the same instance — keep multiple same-type leaks for stair counts.
    _tracked.removeWhere((t) => identical(t.ref.target, resource));
    _tracked.add(
      _Tracked(
        name: n,
        route: r,
        ref: WeakReference(resource),
        registeredAt: DateTime.now(),
      ),
    );
    debugPrint('[TransitionLeakTracker] track $n @ $r');
  }

  void untrack(Object resource, {String? name}) {
    _tracked.removeWhere((t) {
      final target = t.ref.target;
      if (identical(target, resource)) return true;
      if (name != null && t.name == name && target == null) return true;
      return false;
    });
  }

  /// Call when a route is pushed (or becomes active) to stamp RSS + Sleuth.
  void markPush(String route) {
    if (!enabled) return;
    try {
      final snap = PerfSnapshot.capture(sleuth: false);
      _rssAtPush[route] = snap.rssBytes / (1024 * 1024);
    } catch (_) {}
    SleuthTransitionBinder.instance.stampPush(route);
  }

  /// After pop: wait [settleMs], then WeakRef + Sleuth window diff.
  Future<TransitionLeakProbe> probeAfterPop({
    required String poppedRoute,
    int? settleOverrideMs,
  }) async {
    final wait = settleOverrideMs ?? settleMs;
    final rssBefore = _rssAtPush[poppedRoute];
    await Future<void>.delayed(Duration(milliseconds: wait));

    // Drop dead refs first.
    _tracked.removeWhere((t) => t.ref.target == null);

    final alive = <Map<String, dynamic>>[];
    for (final t in _tracked) {
      if (!_routeMatch(t.route, poppedRoute)) continue;
      final obj = t.ref.target;
      if (obj == null) continue;
      alive.add({
        'name': t.name,
        'route': t.route,
        'type': obj.runtimeType.toString(),
        'registeredAt': t.registeredAt.toIso8601String(),
      });
    }

    final key = _historyKey(poppedRoute);
    final history = _aliveHistory.putIfAbsent(key, () => <int>[]);
    history.add(alive.length);
    while (history.length > 20) {
      history.removeAt(0);
    }

    final multi = _isMultiRoundConfirmed(history);
    final sleuthHits =
        SleuthTransitionBinder.instance.diffSincePush(poppedRoute);

    double? rssAfter;
    try {
      final snap = PerfSnapshot.capture(sleuth: false);
      rssAfter = snap.rssBytes / (1024 * 1024);
    } catch (_) {}

    return TransitionLeakProbe(
      route: poppedRoute,
      alive: alive,
      rssBeforeMb: rssBefore,
      rssAfterMb: rssAfter,
      settleMs: wait,
      roundIndex: history.length,
      aliveCounts: List<int>.from(history),
      multiRoundConfirmed: multi,
      sleuthHits: sleuthHits,
    );
  }

  /// Last [leakConfirmRounds] counts are all > 0 and non-decreasing (stair/hold).
  bool _isMultiRoundConfirmed(List<int> history) {
    final n = leakConfirmRounds;
    if (history.length < n) return false;
    final window = history.sublist(history.length - n);
    if (window.any((c) => c <= 0)) return false;
    for (var i = 1; i < window.length; i++) {
      if (window[i] < window[i - 1]) return false;
    }
    return true;
  }

  /// Build alerts for a pop transition (leak + optional RSS retain / jank).
  List<AlertItem> alertsForProbe({
    required TransitionLeakProbe probe,
    required String stepId,
    required String action,
    double? p90FrameMs,
    int? jankDelta,
    double maxFrameCostMs = 16,
  }) {
    final out = <AlertItem>[];
    if (probe.hasLeak) {
      final parts = <String>[];
      if (probe.hasWeakRefLeak) {
        final names = probe.alive.map((e) => e['name']).join(', ');
        parts.add('仍可达: $names（WeakRef）');
      }
      if (probe.hasSleuthLeak) {
        final titles = probe.sleuthHits
            .map((e) => e['title'] ?? e['stableId'] ?? '?')
            .join(', ');
        parts.add('Sleuth: $titles');
      }
      final multiNote = probe.multiRoundConfirmed
          ? '；多轮确认：${probe.multiRoundSummary}'
          : '';
      out.add(
        AlertItem(
          type: 'transition_memory_leak',
          stepId: stepId,
          action: action,
          message:
              'pop ${probe.route} 后 ${parts.join('；')}$multiNote'
              ' · evidence=${probe.evidence}',
          value: probe.toJson(),
        ),
      );
    }
    final delta = probe.rssDeltaMb;
    if (delta != null && delta >= rssRetainMb) {
      out.add(
        AlertItem(
          type: 'transition_memory_retain_rss',
          stepId: stepId,
          action: action,
          message:
              'pop ${probe.route} 后 RSS 辅证滞留 ${delta.toStringAsFixed(2)} MB '
              '≥ ${rssRetainMb}MB（非定罪）',
          value: delta,
          threshold: rssRetainMb,
        ),
      );
    }
    if (p90FrameMs != null && p90FrameMs > maxFrameCostMs) {
      out.add(
        AlertItem(
          type: 'transition_jank',
          stepId: stepId,
          action: action,
          message:
              '转场窗 P90 ${p90FrameMs.toStringAsFixed(1)}ms > ${maxFrameCostMs}ms',
          value: p90FrameMs,
          threshold: maxFrameCostMs,
        ),
      );
    } else if (jankDelta != null && jankDelta > 0) {
      out.add(
        AlertItem(
          type: 'transition_jank',
          stepId: stepId,
          action: action,
          message: '转场窗新增 Jank $jankDelta 次',
          value: jankDelta,
        ),
      );
    }
    return out;
  }

  static String _historyKey(String route) => route.split('#').first;

  static bool _routeMatch(String a, String b) {
    if (a == b) return true;
    return a.split('#').first == b.split('#').first;
  }
}

// PerfLeakTrackMixin / PerfGetxController / PerfDi live in getx_leak_hook.dart.
