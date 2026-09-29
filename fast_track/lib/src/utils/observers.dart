import 'dart:async';

import 'package:flutter/widgets.dart';

import '../fast_tracker.dart';
import 'storage.dart';

/// 自动埋点事件名常量
class FastTrackEventName {
  FastTrackEventName._();

  static const appStart = 'app_start';
  static const appForeground = 'app_foreground';
  static const appBackground = 'app_background';
  static const appSession = 'app_session';
  static const appFirstOpen = 'app_first_open';
  static const appDailyActive = 'app_daily_active';
  static const pageView = 'page_view';
  static const pageStay = 'page_stay';
  static const appCrash = 'app_crash';
}

/// App 生命周期自动集成（前后台切换 + 启动事件）
class FastTrackLifecycleObserver with WidgetsBindingObserver {
  bool _started = false;
  DateTime? _lastResumeTime;

  /// 防止 iOS 切后台时 inactive → paused 重复触发
  bool _backgroundTracked = false;

  /// 开始监听，在 App 启动时调用一次
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);

    final tracker = FastTracker.tracker;
    tracker.onForeground();

    _trackFirstOpen();
    _trackDailyActive();

    FastTracker.track(FastTrackEventName.appStart);
    _lastResumeTime = DateTime.now();
  }

  /// 停止监听，可选
  void stop() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _backgroundTracked = false;
        FastTracker.tracker.onForeground();
        _trackDailyActive();
        FastTracker.track(FastTrackEventName.appForeground);
        _lastResumeTime = DateTime.now();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // iOS 切后台依次触发 inactive → paused（→ detached），用标志防止重复记录
        if (!_backgroundTracked) {
          _backgroundTracked = true;
          FastTracker.track(FastTrackEventName.appBackground);
          if (_lastResumeTime != null) {
            final duration = DateTime.now().difference(_lastResumeTime!).inMilliseconds;
            if (duration > 0) {
              FastTracker.track(
                FastTrackEventName.appSession,
                properties: {'duration_ms': duration},
              );
            }
          }
        }
        // 退场/切后台时立即 flush，减少进程被 kill 导致未发事件丢失
        unawaited(FastTracker.tracker.flush());
        break;
      case AppLifecycleState.hidden:
        // Web / desktop 特有状态，这里暂时忽略
        break;
    }
  }

  /// 首次启动（安装后第一次启动）
  void _trackFirstOpen() {
    if (Storage.firstOpenFlag) return;
    FastTracker.track(FastTrackEventName.appFirstOpen);
    Storage.setFirstOpenFlag(true);
  }

  /// 日活（同一自然日只记一次）
  void _trackDailyActive() {
    final today = DateTime.now();
    final todayKey = '${today.year}-${today.month}-${today.day}';
    if (Storage.getLastActiveDate() == todayKey) return;

    FastTracker.track(FastTrackEventName.appDailyActive, properties: {
      'date': todayKey,
    });
    Storage.setLastActiveDate(todayKey);
  }
}

/// 页面路由自动埋点（page_view + 停留时长）
class FastTrackNavigatorObserver extends NavigatorObserver {
  final Map<Route<dynamic>, DateTime> _enterTimes = {};

  String? _routeName(Route<dynamic>? route) {
    if (route == null) return null;
    return route.settings.name ?? route.runtimeType.toString();
  }

  void _trackPage(Route<dynamic>? route, {Route<dynamic>? from}) {
    final page = _routeName(route);
    if (page == null) return;

    final props = <String, dynamic>{'page_name': page};
    final fromName = _routeName(from);
    if (fromName != null) {
      props['from_page'] = fromName;
    }
    FastTracker.track(FastTrackEventName.pageView, properties: props);
  }

  void _markEnter(Route<dynamic>? route) {
    if (route == null) return;
    _enterTimes[route] = DateTime.now();
  }

  void _markExit(Route<dynamic>? route) {
    if (route == null) return;
    final enter = _enterTimes.remove(route);
    if (enter == null) return;
    final duration = DateTime.now().difference(enter).inMilliseconds;
    if (duration <= 0) return;

    FastTracker.track(FastTrackEventName.pageStay, properties: {
      'page_name': _routeName(route),
      'duration_ms': duration,
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _markExit(previousRoute);
    _markEnter(route);
    _trackPage(route, from: previousRoute);
    super.didPush(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _markExit(oldRoute);
    _markEnter(newRoute);
    _trackPage(newRoute, from: oldRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _markExit(route);
    _markEnter(previousRoute);
    _trackPage(previousRoute, from: route);
    super.didPop(route, previousRoute);
  }
}

typedef FastTrackAppRunner = FutureOr<void> Function();

/// 崩溃自动采集：捕获 FlutterError 和 Zone 未捕获异常
class FastTrackCrashHandler {
  static bool _initialized = false;

  static Future<void> run(FastTrackAppRunner appRunner) async {
    if (_initialized) {
      await appRunner();
      return;
    }
    _initialized = true;

    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);

      // 记录崩溃事件并立即 flush，避免进程退出前丢失
      unawaited(
        FastTracker.track(
          FastTrackEventName.appCrash,
          properties: {
            'type': 'flutter_error',
            'exception': details.exceptionAsString(),
            'stack': details.stack?.toString(),
            'library': details.library,
            'context': details.context?.toDescription(),
          },
        ).then((_) {
          // 立即 flush，尽力发送崩溃事件
          return FastTracker.tracker.flush();
        }),
      );
    };

    return runZonedGuarded(
      () async {
        await appRunner();
      },
      (Object error, StackTrace stack) {
        // 记录崩溃事件并立即 flush，避免进程退出前丢失
        unawaited(
          FastTracker.track(
            FastTrackEventName.appCrash,
            properties: {
              'type': 'zone_error',
              'exception': error.toString(),
              'stack': stack.toString(),
            },
          ).then((_) {
            // 立即 flush，尽力发送崩溃事件
            return FastTracker.tracker.flush();
          }),
        );
      },
    );
  }
}
