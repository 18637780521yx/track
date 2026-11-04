import 'package:flutter/foundation.dart';
import 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';

import 'leak_online.dart';
import '../network/network_capture.dart';
import '../session/perf_snapshot.dart';

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

  bool get hasWeakRefLeak => alive.isNotEmpty;

  /// Kept for older call sites. Leak detection is WeakRef + RSS only.
  @Deprecated('Leak detection no longer uses an external issue window.')
  bool get hasSleuthLeak => false;

  bool get hasLeak => hasWeakRefLeak;

  double? get rssDeltaMb {
    if (rssBeforeMb == null || rssAfterMb == null) return null;
    return double.parse((rssAfterMb! - rssBeforeMb!).toStringAsFixed(3));
  }

  String get multiRoundSummary {
    if (aliveCounts.isEmpty) return '';
    final series = aliveCounts.join('→');
    return '同路由 ${aliveCounts.length} 次进出存活数 [$series]';
  }

  /// weak_ref_multi | weak_ref | none
  String get evidence {
    if (!hasWeakRefLeak) return 'none';
    return multiRoundConfirmed ? 'weak_ref_multi' : 'weak_ref';
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
        'sleuthHits': const <Map<String, dynamic>>[],
        'evidence': evidence,
      };
}

/// Registers objects per route and checks WeakRef liveness after pop.
///
/// Does **not** call VM forced GC — still-reachable objects are leaks.
/// Keeps per-route [aliveCounts] history for multi-round confirmation.
/// A leak is WeakRef liveness plus optional RSS retain.
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

  /// Gate: emit main leak alert when WeakRef alive (unless [requireMultiRound]).
  bool alertOnWeakRef = true;

  /// Gate: only alert WeakRef when [multiRoundConfirmed].
  bool requireMultiRound = false;

  /// Gate: RSS retain auxiliary alert.
  bool alertOnRssRetain = true;

  /// Opt-in VM deep probe flag (MCP performs GC/profile; ignored in release).
  bool leakVmDeepProbe = false;

  final List<_Tracked> _tracked = [];
  final Map<String, double> _rssAtPush = {};

  /// routeKey → aliveCount after each pop (session-scoped).
  final Map<String, List<int>> _aliveHistory = {};

  void clear() {
    _tracked.clear();
    _rssAtPush.clear();
    _aliveHistory.clear();
  }

  /// Apply config from [FastTrackMcp.ensureInitialized] / MCP session start.
  void configure({
    bool? enabled,
    int? settleMs,
    int? leakConfirmRounds,
    double? rssRetainMb,
    bool? alertOnWeakRef,
    bool? requireMultiRound,
    bool? alertOnRssRetain,
    bool? leakVmDeepProbe,
  }) {
    if (enabled != null) this.enabled = enabled;
    if (settleMs != null && settleMs >= 0) this.settleMs = settleMs;
    if (leakConfirmRounds != null && leakConfirmRounds >= 1) {
      this.leakConfirmRounds = leakConfirmRounds;
    }
    if (rssRetainMb != null && rssRetainMb >= 0) {
      this.rssRetainMb = rssRetainMb;
    }
    if (alertOnWeakRef != null) this.alertOnWeakRef = alertOnWeakRef;
    if (requireMultiRound != null) this.requireMultiRound = requireMultiRound;
    if (alertOnRssRetain != null) this.alertOnRssRetain = alertOnRssRetain;
    if (leakVmDeepProbe != null) {
      // Never enable VM deep probe on the device release path.
      this.leakVmDeepProbe = kReleaseMode ? false : leakVmDeepProbe;
    }
  }

  /// Whether the gate policy allows a main `memory_leak` alert.
  bool shouldAlertLeak(TransitionLeakProbe probe) {
    if (probe.hasWeakRefLeak) {
      if (!alertOnWeakRef) return false;
      if (requireMultiRound && !probe.multiRoundConfirmed) return false;
      return true;
    }
    return false;
  }

  /// Release tracks only when [LeakOnline.active]; debug/profile when [enabled].
  bool get _allowTrack =>
      enabled && (!kReleaseMode || LeakOnline.instance.active);

  /// Register [resource] as owned by [route] (defaults to current route).
  void track(Object resource, {String? name, String? route}) {
    if (!_allowTrack) return;
    final r = route ?? FastTrackMcpNetwork.currentRoute() ?? '(unknown)';
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

  /// Call when a route is pushed (or becomes active) to stamp RSS.
  void markPush(String route) {
    if (!enabled) return;
    try {
      final snap = PerfSnapshot.capture();
      _rssAtPush[route] = snap.rssBytes / (1024 * 1024);
    } catch (_) {}
  }

  /// After pop: wait [settleMs], then WeakRef liveness + RSS delta.
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

    double? rssAfter;
    try {
      final snap = PerfSnapshot.capture();
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
    if (shouldAlertLeak(probe)) {
      final parts = <String>[];
      if (probe.hasWeakRefLeak) {
        final names = probe.alive.map((e) => e['name']).join(', ');
        parts.add('仍可达: $names（WeakRef）');
      }
      final multiNote = probe.multiRoundConfirmed
          ? '；多轮确认：${probe.multiRoundSummary}'
          : '';
      out.add(
        AlertItem(
          type: 'memory_leak',
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
    if (alertOnRssRetain && delta != null && delta >= rssRetainMb) {
      out.add(
        AlertItem(
          type: 'memory_retain_rss',
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
    // Frame jank comes from FastTrackMcpJankMonitor (realtime).
    // p90FrameMs / jankDelta kept on call sites for step.diff only.
    return out;
  }

  static String _historyKey(String route) => route.split('#').first;

  static bool _routeMatch(String a, String b) {
    if (a == b) return true;
    return a.split('#').first == b.split('#').first;
  }
}

// FastTrackMcpLeakTrackMixin / FastTrackMcpGetxController / FastTrackMcpDi live in getx_leak_hook.dart.
