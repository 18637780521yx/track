import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'network_capture.dart';
import 'perf_snapshot.dart';

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
  });

  final String route;
  final List<Map<String, dynamic>> alive;
  final double? rssBeforeMb;
  final double? rssAfterMb;
  final int settleMs;

  bool get hasLeak => alive.isNotEmpty;

  double? get rssDeltaMb {
    if (rssBeforeMb == null || rssAfterMb == null) return null;
    return double.parse((rssAfterMb! - rssBeforeMb!).toStringAsFixed(3));
  }

  Map<String, dynamic> toJson() => {
        'route': route,
        'aliveCount': alive.length,
        'alive': alive,
        'rssBeforeMb': rssBeforeMb,
        'rssAfterMb': rssAfterMb,
        'rssDeltaMb': rssDeltaMb,
        'settleMs': settleMs,
        'evidence': 'weak_ref',
      };
}

/// Registers objects per route and checks WeakRef liveness after pop.
///
/// Does **not** call VM forced GC — still-reachable objects are leaks.
class TransitionLeakTracker {
  TransitionLeakTracker._();
  static final TransitionLeakTracker instance = TransitionLeakTracker._();

  bool enabled = true;
  int settleMs = 1500;
  /// RSS retain (MB) for auxiliary alert only.
  double rssRetainMb = 5;

  final List<_Tracked> _tracked = [];
  final Map<String, double> _rssAtPush = {};

  void clear() {
    _tracked.clear();
    _rssAtPush.clear();
  }

  /// Register [resource] as owned by [route] (defaults to current route).
  void track(Object resource, {String? name, String? route}) {
    if (!enabled || kReleaseMode) return;
    final r = route ?? PerfNetworkCapture.currentRoute() ?? '(unknown)';
    final n = name ?? resource.runtimeType.toString();
    _tracked.removeWhere(
      (t) => identical(t.ref.target, resource) || (t.name == n && t.route == r),
    );
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

  /// Call when a route is pushed (or becomes active) to stamp RSS baseline.
  void markPush(String route) {
    if (!enabled) return;
    try {
      final snap = PerfSnapshot.capture(sleuth: false);
      _rssAtPush[route] = snap.rssBytes / (1024 * 1024);
    } catch (_) {}
  }

  /// After pop: wait [settleMs], then list registrations for [poppedRoute]
  /// whose WeakRef is still alive.
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
    );
  }

  /// Build alerts for a pop transition (leak + optional RSS retain).
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
      final names = probe.alive.map((e) => e['name']).join(', ');
      out.add(
        AlertItem(
          type: 'transition_memory_leak',
          stepId: stepId,
          action: action,
          message:
              'pop ${probe.route} 后仍可达: $names（WeakRef，未强制 GC）',
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

  static bool _routeMatch(String a, String b) {
    if (a == b) return true;
    // Match base path ignoring tab hash: /home#mine vs /home
    return a.split('#').first == b.split('#').first;
  }
}

/// Mixin for GetxController: auto track onInit / untrack onClose.
mixin PerfLeakTrackMixin on Object {
  String get leakTrackName => runtimeType.toString();

  void perfTrackLeak({String? route}) {
    TransitionLeakTracker.instance.track(
      this,
      name: leakTrackName,
      route: route,
    );
  }

  void perfUntrackLeak() {
    TransitionLeakTracker.instance.untrack(this, name: leakTrackName);
  }
}
