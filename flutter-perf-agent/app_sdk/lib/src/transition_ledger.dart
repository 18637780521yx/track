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

  /// `push` | `pop` | `replace` | `remove` | `route_change` |
  /// `modal_dialog` | `modal_sheet` | `modal_page`
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

/// Classify [route] into a modal_* kind, or null for normal page routes.
String? classifyModalKind(Route<dynamic> route) {
  final typeName = route.runtimeType.toString();
  if (typeName.contains('BottomSheet')) return 'modal_sheet';
  if (route is PopupRoute) {
    if (typeName.contains('Dialog') || typeName.contains('RawDialog')) {
      return 'modal_dialog';
    }
    // Generic popup (menu, etc.) — treat as dialog for leak pairing.
    return 'modal_dialog';
  }
  if (route is PageRoute && route.fullscreenDialog) {
    return 'modal_page';
  }
  return null;
}

/// Route shell without `#tab` / fragment (e.g. `/home#mine` → `/home`).
String routeShell(String? route) {
  if (route == null || route.isEmpty) return '';
  return route.split('#').first;
}

/// Same Navigator/GetX page, only logical tab / fragment changed.
bool isTabOnlyRouteChange(String? from, String? to) {
  if (from == null || to == null || from == to) return false;
  final a = routeShell(from);
  final b = routeShell(to);
  return a.isNotEmpty && a == b;
}

/// True when [kind] indicates a closing transition that should run leak probe.
///
/// Tab-only changes (`/home#home` → `/home#mine`) never probe — shell
/// controllers stay alive by design.
bool isClosingTransitionKind(
  String kind, {
  String? fromRoute,
  String? toRoute,
}) {
  if (isTabOnlyRouteChange(fromRoute, toRoute)) return false;
  if (kind == 'tab_change') return false;
  if (kind == 'pop' || kind == 'remove') {
    // `remove` from GetX offAll is a real leave only when shells differ
    // (or we lack [toRoute] and must trust kind).
    if (toRoute != null &&
        fromRoute != null &&
        routeShell(fromRoute) == routeShell(toRoute)) {
      return false;
    }
    return true;
  }
  if (!kind.startsWith('modal_')) return false;
  // Opening a modal uses the same kind; only probe when leaving a modal route.
  final from = fromRoute ?? '';
  return from.startsWith('#modal/') || from.contains('#modal/');
}

/// Stack-aware ledger of route transitions (no VM / no forced GC).
class TransitionLedger {
  TransitionLedger._();
  static final TransitionLedger instance = TransitionLedger._();

  final List<String> _stack = [];
  TransitionRecord? last;
  int settleMs = 1500;
  int _modalSeq = 0;

  /// identityHashCode(route) → synthetic `#modal/N` for nameless popups.
  final Map<int, String> _syntheticNames = {};

  List<String> get stack => List.unmodifiable(_stack);

  void reset() {
    _stack.clear();
    last = null;
    _syntheticNames.clear();
    _modalSeq = 0;
  }

  String? get currentLogical {
    try {
      return PerfNetworkCapture.currentRoute();
    } catch (_) {
      return null;
    }
  }

  /// Resolve display/track name for [route] (settings.name or synthetic).
  String? nameForRoute(Route<dynamic>? route) {
    if (route == null) return null;
    final n = route.settings.name;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    final modal = classifyModalKind(route);
    if (modal == null) return null;
    final id = identityHashCode(route);
    return _syntheticNames.putIfAbsent(id, () {
      _modalSeq += 1;
      return '#modal/$_modalSeq';
    });
  }

  void onPush(String? name, {String kind = 'push'}) {
    final to = _name(name);
    final from = _stack.isEmpty ? currentLogical : _stack.last;
    if (to != null) _stack.add(to);
    last = TransitionRecord(
      kind: kind,
      from: from,
      to: to ?? from,
      at: DateTime.now(),
    );
    if (to != null) {
      TransitionLeakTracker.instance.markPush(to);
    }
    LeakOnline.instance.emitBreadcrumb(
      kind: kind,
      from: last!.from,
      to: last!.to,
    );
    debugPrint('[TransitionLedger] $kind ${last!.from} → ${last!.to}');
  }

  void onPop(String? name, {String kind = 'pop'}) {
    final popped = _name(name);
    String? from = popped;
    if (_stack.isNotEmpty) {
      from = _stack.removeLast();
    }
    final to = _stack.isNotEmpty ? _stack.last : currentLogical;
    last = TransitionRecord(
      kind: kind,
      from: from ?? popped,
      to: to,
      at: DateTime.now(),
    );
    final route = last!.from;
    LeakOnline.instance.emitBreadcrumb(
      kind: kind,
      from: last!.from,
      to: last!.to,
    );
    if (LeakOnline.instance.active && route != null && route.isNotEmpty) {
      // ignore: unawaited_futures
      _onlineProbeAfterPop(route);
    }
    debugPrint('[TransitionLedger] $kind ${last!.from} → ${last!.to}');
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
  ///
  /// Never reuse a stale [last.kind] for an unrelated edge (that caused
  /// Tab switches to inherit `remove` from a prior GetX offAll).
  String resolveKind({required String? from, required String? to}) {
    if (isTabOnlyRouteChange(from, to)) return 'tab_change';

    final rec = last;
    if (rec != null &&
        _edgeMatches(rec.from, rec.to, from, to) &&
        DateTime.now().difference(rec.at).inSeconds < 5) {
      return rec.kind;
    }
    if (from != null && to != null && from != to) {
      // Closing a synthetic modal without a matching last record.
      if (from.startsWith('#modal/')) return 'modal_dialog';
      // GetX offAll / replace often surfaces as remove of the leaving page.
      if (rec != null &&
          rec.kind == 'remove' &&
          _same(rec.from, from) &&
          DateTime.now().difference(rec.at).inSeconds < 5) {
        return 'remove';
      }
      return 'route_change';
    }
    return 'route_change';
  }

  /// Exact edge match (shell-aware on each endpoint).
  static bool _edgeMatches(
    String? recFrom,
    String? recTo,
    String? from,
    String? to,
  ) {
    return _same(recFrom, from) && _same(recTo, to);
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

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final modal = classifyModalKind(route);
    final name = _ledger.nameForRoute(route) ?? _ledger.currentLogical;
    _ledger.onPush(name, kind: modal ?? 'push');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final modal = classifyModalKind(route);
    final name = _ledger.nameForRoute(route) ?? _ledger.currentLogical;
    // Keep modal_* on close so reports show dialog/sheet/page; probe via
    // [isClosingTransitionKind] (fromRoute starts with #modal/).
    _ledger.onPop(name, kind: modal ?? 'pop');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _ledger.onReplace(
      oldName: _ledger.nameForRoute(oldRoute),
      newName: _ledger.nameForRoute(newRoute) ?? _ledger.currentLogical,
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _ledger.onRemove(_ledger.nameForRoute(route));
  }
}
