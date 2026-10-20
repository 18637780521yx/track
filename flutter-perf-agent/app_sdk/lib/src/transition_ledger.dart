import 'package:flutter/material.dart';

import 'leak_online.dart';
import 'network_capture.dart';
import 'transition_leak_tracker.dart';

/// Last Navigator/GetX transition observed by [TransitionObserver].
class TransitionRecord {
  const TransitionRecord({
    required this.kind,
    required this.from,
    required this.to,
    required this.at,
  });

  /// `push` | `pop` | `replace` | `remove` | `route_change`
  final String kind;
  final String? from;
  final String? to;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'transitionKind': kind,
        'from': from,
        'to': to,
        'at': at.toIso8601String(),
      };
}

/// Stack-aware ledger of route transitions (no VM / no forced GC).
class TransitionLedger {
  TransitionLedger._();
  static final TransitionLedger instance = TransitionLedger._();

  final List<String> _stack = [];
  TransitionRecord? last;
  int settleMs = 1500;

  List<String> get stack => List.unmodifiable(_stack);

  void reset() {
    _stack.clear();
    last = null;
  }

  String? get currentLogical {
    try {
      return PerfNetworkCapture.currentRoute();
    } catch (_) {
      return null;
    }
  }

  void onPush(String? name) {
    final to = _name(name);
    final from = _stack.isEmpty ? currentLogical : _stack.last;
    if (to != null) _stack.add(to);
    last = TransitionRecord(
      kind: 'push',
      from: from,
      to: to ?? from,
      at: DateTime.now(),
    );
    if (to != null) {
      TransitionLeakTracker.instance.markPush(to);
    }
    LeakOnline.instance.emitBreadcrumb(
      kind: 'push',
      from: last!.from,
      to: last!.to,
    );
    debugPrint('[TransitionLedger] push ${last!.from} → ${last!.to}');
  }

  void onPop(String? name) {
    final popped = _name(name);
    String? from = popped;
    if (_stack.isNotEmpty) {
      from = _stack.removeLast();
    }
    final to = _stack.isNotEmpty ? _stack.last : currentLogical;
    last = TransitionRecord(
      kind: 'pop',
      from: from ?? popped,
      to: to,
      at: DateTime.now(),
    );
    final route = last!.from;
    LeakOnline.instance.emitBreadcrumb(
      kind: 'pop',
      from: last!.from,
      to: last!.to,
    );
    if (LeakOnline.instance.active && route != null && route.isNotEmpty) {
      // ignore: unawaited_futures
      _onlineProbeAfterPop(route);
    }
    debugPrint('[TransitionLedger] pop ${last!.from} → ${last!.to}');
  }

  Future<void> _onlineProbeAfterPop(String route) async {
    try {
      final probe = await TransitionLeakTracker.instance.probeAfterPop(
        poppedRoute: route,
      );
      if (!probe.hasWeakRefLeak) return;
      LeakOnline.instance.emitTransitionLeak(
        route: probe.route,
        aliveCount: probe.alive.length,
        aliveNames: probe.alive
            .map((e) => e['name']?.toString() ?? '')
            .where((n) => n.isNotEmpty)
            .toList(),
        evidence: probe.evidence,
        aliveCounts: probe.aliveCounts,
        multiRoundConfirmed: probe.multiRoundConfirmed,
      );
    } catch (e) {
      debugPrint('[TransitionLedger] online probe failed: $e');
    }
  }

  void onReplace({String? oldName, String? newName}) {
    final from = _name(oldName) ?? (_stack.isNotEmpty ? _stack.last : null);
    final to = _name(newName);
    if (_stack.isNotEmpty) {
      _stack.removeLast();
    }
    if (to != null) _stack.add(to);
    last = TransitionRecord(
      kind: 'replace',
      from: from,
      to: to,
      at: DateTime.now(),
    );
  }

  void onRemove(String? name) {
    final removed = _name(name);
    if (removed != null) {
      _stack.remove(removed);
    } else if (_stack.isNotEmpty) {
      _stack.removeLast();
    }
    last = TransitionRecord(
      kind: 'remove',
      from: removed,
      to: _stack.isNotEmpty ? _stack.last : currentLogical,
      at: DateTime.now(),
    );
  }

  /// Prefer observer kind when from/to match the last record; else infer.
  String resolveKind({required String? from, required String? to}) {
    final rec = last;
    if (rec != null &&
        _same(rec.from, from) &&
        _same(rec.to, to) &&
        DateTime.now().difference(rec.at).inSeconds < 5) {
      return rec.kind;
    }
    // Heuristic without observer: deeper stack → push; shallower → pop.
    if (from != null && to != null && from != to) {
      if (rec != null && DateTime.now().difference(rec.at).inMilliseconds < 800) {
        return rec.kind;
      }
      return 'route_change';
    }
    return 'route_change';
  }

  static bool _same(String? a, String? b) {
    if (a == null || b == null) return a == b;
    return a == b || a.split('#').first == b.split('#').first;
  }

  static String? _name(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    if (t.isEmpty || t == '/') return t.isEmpty ? null : t;
    return t;
  }
}

/// Attach to [GetMaterialApp.navigatorObservers] / [MaterialApp.navigatorObservers].
class TransitionObserver extends NavigatorObserver {
  TransitionObserver({TransitionLedger? ledger})
      : _ledger = ledger ?? TransitionLedger.instance;

  final TransitionLedger _ledger;

  String? _routeName(Route<dynamic>? route) {
    final n = route?.settings.name;
    if (n != null && n.isNotEmpty) return n;
    return null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _ledger.onPush(_routeName(route) ?? _ledger.currentLogical);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _ledger.onPop(_routeName(route) ?? _ledger.currentLogical);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _ledger.onReplace(
      oldName: _routeName(oldRoute),
      newName: _routeName(newRoute) ?? _ledger.currentLogical,
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _ledger.onRemove(_routeName(route));
  }
}
