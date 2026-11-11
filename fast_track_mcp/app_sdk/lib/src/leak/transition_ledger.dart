import 'package:flutter/material.dart';

import '../detect/detect_sink.dart';
import '../network/network_capture.dart';
import 'leak_online.dart';
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
  /// `modal_dialog` / `modal_sheet` / `modal_page`（旧）|
  /// `modal_*_open` / `modal_*_close`（出现 / 消失）
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
  if (kind.endsWith('_close') && kind.startsWith('modal_')) return true;
  if (kind.endsWith('_open') && kind.startsWith('modal_')) return false;
  if (!kind.startsWith('modal_')) return false;
  // 兼容旧埋点：同为 modal_* 时，只有离开 #modal 才探测泄漏。
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

  /// 锚定壳层路由（如 `/tabs#work`），不发埋点。
  ///
  /// 冷启 / Tab 落地时调用：GetX 常先 push `/`，若不改写栈顶，后续
  /// `Get.toNamed` 的 from 会错成目标页自身。
  void seedShell(String? route) {
    final to = _meaningfulRoute(route);
    if (to == null) return;
    if (_stack.isEmpty) {
      _stack.add(to);
    } else {
      _stack[_stack.length - 1] = to;
    }
  }

  String? get currentLogical {
    try {
      return FastTrackMcpNetwork.currentRoute();
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

  void onPush(String? name, {String kind = 'push', String? fromHint}) {
    // `/tabs` 是 GetX 壳；有 TabsController 时升成 `/tabs#work` 等逻辑路由。
    final to = _enrichShellRoute(_name(name));
    // 栈顶若是 GetX 占位 `/`，优先用逻辑路由 / previousRoute，避免 modal from=/ 。
    final stackTop = _stack.isNotEmpty ? _stack.last : null;
    // GetX 常在 didPush 前就把 currentRoute 改成 to，fromHint/currentLogical
    // 会等于 to，必须回退到栈顶（业务壳层），否则出现 email→email。
    String? from = _meaningfulRoute(fromHint);
    if (from == null || (to != null && from == to)) {
      from = _meaningfulRoute(stackTop);
    }
    if (from == null || (to != null && from == to)) {
      final logical = _meaningfulRoute(currentLogical);
      if (logical != null && logical != to) from = logical;
    }
    if (from == null) from = stackTop;
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
    _trackTransition(last!);
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
    _trackTransition(last!);
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
      if (!TransitionLeakTracker.instance.shouldAlertLeak(probe)) return;
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
    LeakOnline.instance.emitBreadcrumb(
      kind: 'replace',
      from: last!.from,
      to: last!.to,
    );
    _trackTransition(last!);
  }

  void onRemove(String? name) {
    final removed = _name(name);
    if (removed != null) {
      _stack.remove(removed);
    } else if (_stack.isNotEmpty) {
      _stack.removeLast();
    }
    final to = _stack.isNotEmpty ? _stack.last : currentLogical;
    // Get.offAllNamed：先 push 目标页，再 remove 旧页。后者只是清栈，不是用户路径。
    final prev = last;
    final offAllClear = prev != null &&
        (prev.kind == 'push' || prev.kind == 'replace') &&
        to != null &&
        prev.to == to &&
        removed != null &&
        removed != to &&
        DateTime.now().difference(prev.at).inMilliseconds < 2000;
    last = TransitionRecord(
      kind: offAllClear ? 'stack_clear' : 'remove',
      from: removed,
      to: to,
      at: DateTime.now(),
    );
    LeakOnline.instance.emitBreadcrumb(
      kind: last!.kind,
      from: last!.from,
      to: last!.to,
    );
    if (offAllClear) {
      debugPrint(
        '[TransitionLedger] stack_clear ${last!.from} → ${last!.to} (offAll)',
      );
      return;
    }
    _trackTransition(last!);
  }

  /// App-driven logical route change (bottom tab / segment) without Navigator
  /// push — e.g. `/tabs#work` → `/tabs#mine`. Emits `tab_change` + `app_page`.
  ///
  /// Pass [fromName] when the app has already switched its tab index (so
  /// [currentLogical] would already equal [toName]).
  void onLogicalChange(
    String? toName, {
    String? fromName,
    String kind = 'tab_change',
  }) {
    final to = _name(toName);
    if (to == null || to.isEmpty) return;
    final from = _name(fromName) ??
        currentLogical ??
        (_stack.isNotEmpty ? _stack.last : null) ??
        last?.to;
    if (from == to) return;

    // Tab/逻辑路由始终改写当前壳层；否则栈停在 `/`，后续 modal from 会错。
    if (_stack.isEmpty) {
      _stack.add(to);
    } else {
      _stack[_stack.length - 1] = to;
    }

    last = TransitionRecord(
      kind: kind,
      from: from,
      to: to,
      at: DateTime.now(),
    );
    LeakOnline.instance.emitBreadcrumb(
      kind: kind,
      from: last!.from,
      to: last!.to,
    );
    _trackTransition(last!);
    debugPrint('[TransitionLedger] $kind ${last!.from} → ${last!.to}');
  }

  /// Always bury transition + landing page (report reconstruction; not gated
  /// on [LeakOnline]).
  void _trackTransition(TransitionRecord r) {
    final at = r.at.toIso8601String();
    // ignore: unawaited_futures
    FastTrackMcpDetectSink.track(
      'app_transition',
      properties: {
        'kind': r.kind,
        if (r.from != null && r.from!.isNotEmpty) 'from': r.from,
        if (r.to != null && r.to!.isNotEmpty) 'to': r.to,
        'at': at,
      },
    );
    final page = r.to;
    if (page != null && page.isNotEmpty) {
      // ignore: unawaited_futures
      FastTrackMcpDetectSink.track(
        'app_page',
        properties: {
          'route': page,
          'via': r.kind,
          if (r.from != null && r.from!.isNotEmpty) 'from': r.from,
          'at': at,
        },
      );
    }
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

  /// `/` 或空不算有效业务路由（GetX 初值占位）。
  static String? _meaningfulRoute(String? raw) {
    final n = _name(raw);
    if (n == null || n.isEmpty || n == '/') return null;
    return n;
  }

  /// 裸壳 `/tabs` → 逻辑路由 `/tabs#work`（来自 [routeProvider]）。
  String? _enrichShellRoute(String? route) {
    final n = _name(route);
    if (n == null) return null;
    if (n.contains('#')) return n;
    final logical = _meaningfulRoute(currentLogical);
    if (logical != null &&
        logical.contains('#') &&
        routeShell(logical) == routeShell(n)) {
      return logical;
    }
    return n;
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
    // to：优先 settings.name；勿直接用 currentLogical（GetX 可能已切到目标页）
    final name = _ledger.nameForRoute(route) ??
        (modal != null ? null : _ledger.currentLogical);
    // from：只信 previousRoute.name；空则交给 onPush 用栈顶回退
    final fromHint = _ledger.nameForRoute(previousRoute);
    final kind = modal != null ? '${modal}_open' : 'push';
    _ledger.onPush(name, kind: kind, fromHint: fromHint);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final modal = classifyModalKind(route);
    final name = _ledger.nameForRoute(route) ?? _ledger.currentLogical;
    // modal_*_close = 消失；泄漏探测看 isClosingTransitionKind。
    final kind = modal != null ? '${modal}_close' : 'pop';
    _ledger.onPop(name, kind: kind);
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
