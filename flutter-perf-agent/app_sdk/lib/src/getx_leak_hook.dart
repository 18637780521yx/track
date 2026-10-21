import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import 'leak_online.dart';
import 'transition_leak_tracker.dart';
import 'transition_ledger.dart';

/// True when WeakRef track / TransitionObserver should run.
bool get leakHooksActive =>
    !kReleaseMode || LeakOnline.instance.active;

/// Binding-level DI helpers that auto-[TransitionLeakTracker.track] on create.
///
/// Prefer these over raw `Get.put` / `Get.lazyPut` for controllers that should
/// participate in transition leak probes. Route is taken from [route], else the
/// [runWithRoute] scope (set by [PerfLeakMiddleware]), else [Get.currentRoute].
class PerfDi {
  PerfDi._();

  static final List<String> _routeStack = <String>[];

  /// Current route scope from [runWithRoute], or null.
  static String? get routeScope =>
      _routeStack.isEmpty ? null : _routeStack.last;

  /// Run [fn] with [route] pushed on the scope stack (used by middleware).
  static T runWithRoute<T>(String route, T Function() fn) {
    _routeStack.add(route);
    try {
      return fn();
    } finally {
      _routeStack.removeLast();
    }
  }

  static String _resolveRoute(String? route) {
    if (route != null && route.isNotEmpty) return route;
    final scoped = routeScope;
    if (scoped != null && scoped.isNotEmpty) return scoped;
    try {
      final cur = Get.currentRoute;
      if (cur.isNotEmpty) return cur;
    } catch (_) {}
    return '(unknown)';
  }

  static void _track(Object instance, {String? route, String? name}) {
    TransitionLeakTracker.instance.track(
      instance,
      name: name ?? instance.runtimeType.toString(),
      route: _resolveRoute(route),
    );
  }

  /// Same as [Get.put], then optionally track the instance.
  ///
  /// Set [trackLeak] false for long-lived shell / Tab controllers that must
  /// outlive `#tab` logical route changes.
  static S put<S>(
    S dependency, {
    String? tag,
    bool permanent = false,
    String? route,
    bool trackLeak = true,
  }) {
    final result = Get.put<S>(dependency, tag: tag, permanent: permanent);
    if (trackLeak && result is Object) {
      _track(result as Object, route: route);
    }
    return result;
  }

  /// Same as [Get.lazyPut], wrapping the factory to track on first create.
  static void lazyPut<S>(
    InstanceBuilderCallback<S> builder, {
    String? tag,
    bool fenix = false,
    String? route,
    bool trackLeak = true,
  }) {
    Get.lazyPut<S>(
      () {
        final instance = builder();
        if (trackLeak && instance is Object) {
          _track(instance as Object, route: route);
        }
        return instance;
      },
      tag: tag,
      fenix: fenix,
    );
  }

  /// Same as [Get.putAsync], tracking after the future completes.
  static Future<S> putAsync<S>(
    AsyncInstanceBuilderCallback<S> builder, {
    String? tag,
    bool permanent = false,
    String? route,
    bool trackLeak = true,
  }) async {
    final result = await Get.putAsync<S>(
      builder,
      tag: tag,
      permanent: permanent,
    );
    if (trackLeak && result is Object) {
      _track(result as Object, route: route);
    }
    return result;
  }
}

/// Wraps [Bindings.dependencies] in a [PerfDi.runWithRoute] scope.
class _ScopedBindings extends Bindings {
  _ScopedBindings(this.inner, this.route);

  final Bindings inner;
  final String route;

  @override
  void dependencies() {
    PerfDi.runWithRoute(route, () => inner.dependencies());
  }
}

/// GetX middleware: stamp route scope around page Bindings.
///
/// Inject via [PerfAgent.instrumentGetPages] (one instance per [GetPage]).
class PerfLeakMiddleware extends GetMiddleware {
  PerfLeakMiddleware({this.routeName, int? priority})
      : super(priority: priority ?? -1000);

  /// Fixed route for this page (set by [PerfAgent.instrumentGetPages]).
  final String? routeName;

  String? _pageRoute;

  @override
  GetPage? onPageCalled(GetPage? page) {
    _pageRoute = routeName ?? page?.name;
    return page;
  }

  @override
  List<Bindings>? onBindingsStart(List<Bindings>? bindings) {
    final route = _pageRoute ?? routeName;
    if (bindings == null || route == null || route.isEmpty) return bindings;
    return bindings
        .map((b) => b is _ScopedBindings ? b : _ScopedBindings(b, route))
        .toList();
  }
}

/// Mixin: auto-track on [onInit]. Default does **not** untrack on [onClose]
/// (so GetX delete + external retain still shows as WeakRef leak).
///
/// Set [leakUntrackOnClose] true to drop from the registry when closed
/// (reduces noise for long-lived tab controllers that dispose cleanly).
mixin PerfLeakTrackMixin on GetxController {
  String get leakTrackName => runtimeType.toString();

  /// When true, [onClose] calls [perfUntrackLeak]. Default false.
  bool get leakUntrackOnClose => false;

  /// Optional fixed route; otherwise current / PerfDi scope.
  String? get leakTrackRoute => null;

  @override
  void onInit() {
    super.onInit();
    if (leakHooksActive) {
      perfTrackLeak(route: leakTrackRoute);
    }
  }

  @override
  void onClose() {
    if (leakHooksActive && leakUntrackOnClose) {
      perfUntrackLeak();
    }
    super.onClose();
  }

  void perfTrackLeak({String? route}) {
    TransitionLeakTracker.instance.track(
      this,
      name: leakTrackName,
      route: route ?? leakTrackRoute ?? PerfDi.routeScope,
    );
  }

  void perfUntrackLeak() {
    TransitionLeakTracker.instance.untrack(this, name: leakTrackName);
  }
}

/// Drop-in [GetxController] that auto-tracks on init (same rules as mixin).
abstract class PerfGetxController extends GetxController
    with PerfLeakTrackMixin {}

/// Prepend [PerfLeakMiddleware] and recurse into [GetPage.children].
List<GetPage<dynamic>> instrumentGetPages(List<GetPage<dynamic>> pages) {
  return pages.map(_instrumentOne).toList();
}

GetPage<dynamic> _instrumentOne(GetPage<dynamic> page) {
  final existing = page.middlewares ?? <GetMiddleware>[];
  final already = existing.any((m) => m is PerfLeakMiddleware);
  final middlewares = already
      ? existing
      : <GetMiddleware>[PerfLeakMiddleware(routeName: page.name), ...existing];
  final children = page.children.isEmpty
      ? page.children
      : page.children.map(_instrumentOne).toList();
  return page.copy(middlewares: middlewares, children: children);
}

/// Navigator observers for transition ledger / leak markPush.
List<NavigatorObserver> perfNavigatorObservers({bool enabled = true}) {
  if (!enabled) return const <NavigatorObserver>[];
  if (kReleaseMode && !LeakOnline.instance.active) {
    return const <NavigatorObserver>[];
  }
  return <NavigatorObserver>[TransitionObserver()];
}
