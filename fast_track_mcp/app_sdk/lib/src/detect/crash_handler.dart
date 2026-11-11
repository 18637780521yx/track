import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';

import 'detect_sink.dart';
import 'event_names.dart';

typedef FastTrackAppRunner = FutureOr<void> Function();

/// 崩溃与异常采集。
///
/// [run] / [install] 自动挂上：
/// - [FlutterError.onError]：build / layout / paint 等框架异常
/// - [PlatformDispatcher.onError]：根 Zone 上的未捕获异步异常
/// - [Isolate.current] error listener + [isolateErrorPort]
/// - [runZonedGuarded]（仅 [run]）
/// - **原生**（Android/iOS 插件）：JVM/ObjC Uncaught + pending 落盘；
///   Android：`ApplicationExitInfo` + tombstone（ExitInfo trace / 可读时
///   `/data/tombstones`）；iOS 14+：MetricKit crash/hang 诊断
///
/// Zone / Platform / Isolate 未捕获打 `app_crash` 并 flush；框架错误记 `app_error`。
/// 已 catch 的用 [captureException] / [captureMessage] → `app_error`。
class FastTrackMcpCrashHandler {
  FastTrackMcpCrashHandler._();

  static const int _maxMessageLength = 4000;
  static const int _maxStackLength = 32000;
  static const Duration _dedupWindow = Duration(milliseconds: 500);

  static bool _installed = false;
  static final Object _reportZoneKey = Object();
  static Future<void>? _nativeStartFuture;

  static void Function(FlutterErrorDetails details)? _previousFlutterOnError;
  static ErrorCallback? _previousPlatformOnError;
  static RawReceivePort? _isolatePort;
  static StreamSubscription<dynamic>? _nativeCrashSub;
  static bool _nativeCrashStarted = false;
  static final Map<String, Future<void>> _nativeReports = {};
  static final Set<String> _persistedNativeIds = {};

  static const _nativeMethod = MethodChannel('fast_track_mcp/anr');
  static const _nativeCrashEvents = EventChannel('fast_track_mcp/crash_events');

  static final Map<String, DateTime> _recentErrors = {};

  /// 测试注入。设置后只回调、不写队列也不 flush。
  @visibleForTesting
  static Future<void> Function(String name, Map<String, dynamic> properties)?
      debugOnReport;

  @visibleForTesting
  static Future<bool> Function(
    String name, {
    required String eventId,
    required Map<String, dynamic> properties,
    DateTime? timestamp,
    String? sessionId,
  })? debugPersistCrash;

  /// 挂上 Flutter / PlatformDispatcher / 当前 Isolate 的捕获。可重复调用。
  /// Android/iOS 同时启动原生 crash（Uncaught + 下次启动回捞）。
  static void install() {
    if (!_installed) {
      _installed = true;
      _hookFlutterError();
      _hookPlatformDispatcher();
      _listenCurrentIsolate();
    }
    if (_isBindingInitialized()) unawaited(ensureNativeInitialized());
  }

  /// Keep the current Flutter error handler when an integration installs its own.
  /// The temporary proxy also handles integrations that already chain handlers:
  /// each error reaches the original handler once, whether or not they forward it.
  static void preserveFlutterErrorHandler(void Function() initialize) {
    final previous = FlutterError.onError;
    if (previous == null) {
      initialize();
      return;
    }
    final forwarded = Set<FlutterErrorDetails>.identity();
    final dispatching = Set<FlutterErrorDetails>.identity();
    void forward(FlutterErrorDetails details) {
      if (!dispatching.contains(details) || forwarded.add(details)) {
        previous(details);
      }
    }

    FlutterError.onError = forward;
    try {
      initialize();
    } finally {
      final installed = FlutterError.onError;
      if (installed == null || identical(installed, forward)) {
        FlutterError.onError = previous;
      } else {
        FlutterError.onError = (details) {
          if (!dispatching.add(details)) return;
          try {
            try {
              installed(details);
            } catch (error, stack) {
              debugPrint(
                  '[ftm] integration error handler failed: $error\n$stack');
            } finally {
              forward(details);
            }
          } finally {
            dispatching.remove(details);
            forwarded.remove(details);
          }
        };
      }
    }
  }

  /// 先 [install]，再在 guarded zone 里执行 [appRunner]。
  ///
  /// [WidgetsFlutterBinding.ensureInitialized] 和 [runApp] 都要放在 [appRunner] 里。
  /// 绑定位于另一个 Zone 时，部分异步异常进不了这里的 zone 回调，
  /// 仍会由 [PlatformDispatcher.onError] 兜底。
  static Future<void> run(FastTrackAppRunner appRunner) {
    install();
    final completed = Completer<void>();
    runZonedGuarded(() async {
      try {
        WidgetsFlutterBinding.ensureInitialized();
        await ensureNativeInitialized();
        await appRunner();
        await ensureNativeInitialized();
      } catch (error, stack) {
        await _report(
            source: 'zone_error', error: error, stack: stack, fatal: true);
        FlutterError.presentError(
            FlutterErrorDetails(exception: error, stack: stack));
      } finally {
        completed.complete();
      }
    }, (Object error, StackTrace stack) {
      unawaited(_report(
          source: 'zone_error', error: error, stack: stack, fatal: true));
      FlutterError.presentError(
          FlutterErrorDetails(exception: error, stack: stack));
    });
    return completed.future;
  }

  /// Retryable native startup, after Binding and FastTracker initialization.
  static Future<void> ensureNativeInitialized() {
    if (!_preferNativeCrash || !_isBindingInitialized()) return Future.value();
    return _nativeStartFuture ??= _startNativeCrash().whenComplete(() {
      _nativeStartFuture = null;
    });
  }

  /// Pass this port to Isolate.spawn(onError: ...) for child isolate errors.
  static SendPort get isolateErrorPort {
    install();
    return _isolatePort!.sendPort;
  }

  /// 已经 catch 住、仍希望上报的异常。默认 `app_error`；[fatal] 为 true 时记 `app_crash` 并 flush。
  static Future<void> captureException(
    Object exception, {
    StackTrace? stackTrace,
    Map<String, dynamic>? properties,
    bool fatal = false,
  }) {
    return _report(
      source: 'captured',
      error: exception,
      stack: stackTrace ?? StackTrace.current,
      fatal: fatal,
      extra: properties,
      dedup: false,
    );
  }

  /// 没有异常对象的错误说明，记 `app_error`，`exception_type` 为 `CaptureMessage`。
  static Future<void> captureMessage(
    String message, {
    Map<String, dynamic>? properties,
  }) {
    return _report(
      source: 'message',
      error: message,
      stack: StackTrace.current,
      fatal: false,
      exceptionType: 'CaptureMessage',
      extra: properties,
      dedup: false,
    );
  }

  @visibleForTesting
  static Future<void> debugReset() {
    if (_installed) {
      FlutterError.onError = _previousFlutterOnError;
      PlatformDispatcher.instance.onError = _previousPlatformOnError;
    }
    final port = _isolatePort;
    if (port != null) {
      Isolate.current.removeErrorListener(port.sendPort);
      port.close();
      _isolatePort = null;
    }
    _installed = false;

    _previousFlutterOnError = null;
    _previousPlatformOnError = null;
    _recentErrors.clear();
    debugOnReport = null;
    debugPersistCrash = null;
    _nativeReports.clear();
    _persistedNativeIds.clear();
    return _stopNativeCrash();
  }

  static bool get _preferNativeCrash {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static Future<void> _startNativeCrash() async {
    if (!_preferNativeCrash) return;
    try {
      _nativeCrashSub ??= _nativeCrashEvents.receiveBroadcastStream().listen(
        (event) {
          if (event is! Map) return;
          final raw = Map<Object?, Object?>.from(event);
          final id = raw['crash_id']?.toString();
          if (id == null) {
            unawaited(_onNativeCrash(raw));
          } else if (!_nativeReports.containsKey(id)) {
            _nativeReports[id] = _onNativeCrash(raw).whenComplete(() {
              _nativeReports.remove(id);
            });
          }
        },
        onError: (Object e) {
          debugPrint('[ftm] native crash stream error: $e');
        },
      );
      await _nativeMethod.invokeMethod<void>('startCrash', {
        'session_id': FastTracker.tracker.currentSessionId,
      });
      _nativeCrashStarted = true;
      debugPrint('[ftm] native crash handler started');
    } on MissingPluginException {
      await _nativeCrashSub?.cancel();
      _nativeCrashSub = null;
    } catch (e) {
      debugPrint('[ftm] native crash start failed: $e');
      await _nativeCrashSub?.cancel();
      _nativeCrashSub = null;
    }
  }

  static Future<void> _stopNativeCrash() async {
    await _nativeStartFuture;
    try {
      if (_nativeCrashStarted) {
        await _nativeMethod.invokeMethod<void>('stopCrash');
      }
    } catch (_) {}
    await _nativeCrashSub?.cancel();
    _nativeCrashSub = null;
    _nativeCrashStarted = false;
  }

  static Future<void> _onNativeCrash(Map<Object?, Object?> raw) async {
    final source = raw['crash_source']?.toString() ?? 'native';
    final message = raw['message']?.toString() ?? 'native crash';
    final stackText = raw['stack']?.toString() ?? '';
    final tombstone = raw['tombstone']?.toString();
    final exceptionType = raw['exception_type']?.toString() ?? 'NativeCrash';
    final thread = raw['thread']?.toString();
    final fatal = raw['is_fatal'] != false;
    await _report(
      nativeId: raw['crash_id']?.toString(),
      source: 'native_$source',
      error: message,
      stack: stackText.isEmpty ? null : StackTrace.fromString(stackText),
      fatal: fatal,
      message: message,
      exceptionType: exceptionType,
      thread: thread,
      extra: {
        'platform': raw['platform'],
        if (raw['crash_id'] != null) 'crash_id': raw['crash_id'],
        if (raw['session_id'] != null) 'original_session_id': raw['session_id'],
        if (raw['occurred_at_ms'] != null)
          'occurred_at_ms': raw['occurred_at_ms'],
        'crash_source': source,
        if (raw['exit_timestamp_ms'] != null)
          'exit_timestamp_ms': raw['exit_timestamp_ms'],
        if (raw['exit_reason'] != null) 'exit_reason': raw['exit_reason'],
        if (tombstone != null && tombstone.isNotEmpty) 'tombstone': tombstone,
        if (raw['tombstone_source'] != null)
          'tombstone_source': raw['tombstone_source'],
        if (raw['tombstone_path'] != null)
          'tombstone_path': raw['tombstone_path'],
        if (raw['blocked_ms'] != null) 'blocked_ms': raw['blocked_ms'],
      },
      dedup: false,
    );
  }

  static void _hookFlutterError() {
    _previousFlutterOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      unawaited(_report(
        source: 'flutter_error',
        error: details.exception,
        stack: details.stack,
        fatal: false,
        message: details.exceptionAsString(),
        library: details.library,
        context: details.context?.toDescription(),
      ));
      final previous = _previousFlutterOnError;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
  }

  static void _hookPlatformDispatcher() {
    _previousPlatformOnError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      unawaited(_report(
        source: 'platform_error',
        error: error,
        stack: stack,
        fatal: true,
      ));
      final previous = _previousPlatformOnError;
      if (previous != null) {
        try {
          previous(error, stack);
        } catch (e) {
          debugPrint('[ftm] previous PlatformDispatcher.onError failed: $e');
        }
      } else {
        FlutterError.presentError(
            FlutterErrorDetails(exception: error, stack: stack));
      }
      return true;
    };
  }

  static void _listenCurrentIsolate() {
    if (_isolatePort != null) return;
    final port = RawReceivePort(_onIsolateErrorMessage);
    _isolatePort = port;
    Isolate.current.addErrorListener(port.sendPort);
  }

  static void _onIsolateErrorMessage(dynamic message) {
    if (message is! List || message.length < 2) return;
    final error = message[0] ?? 'isolate error';
    final stackText = message[1]?.toString() ?? '';
    unawaited(_report(
      source: 'isolate_error',
      error: error,
      stack: StackTrace.fromString(stackText),
      fatal: true,
      thread: 'isolate',
    ));
  }

  static Future<void> _report({
    required String source,
    required Object error,
    required StackTrace? stack,
    required bool fatal,
    String? message,
    String? library,
    String? context,
    String? exceptionType,
    String? thread,
    Map<String, dynamic>? extra,
    bool dedup = true,
    String? nativeId,
  }) async {
    if (Zone.current[_reportZoneKey] == true) return;
    await runZoned(() async {
      try {
        if (dedup && _isDuplicate(error, stack)) return;

        final properties = _properties(
          source: source,
          error: error,
          stack: stack,
          fatal: fatal,
          message: message,
          library: library,
          context: context,
          exceptionType: exceptionType,
          thread: thread,
          extra: extra,
        );
        final name = fatal
            ? FastTrackMcpEventName.appCrash
            : FastTrackMcpEventName.appError;

        final hook = debugOnReport;
        if (hook != null) {
          await hook(name, properties);
          return;
        }
        if (nativeId != null) {
          if (_persistedNativeIds.contains(nativeId)) {
            await _nativeMethod
                .invokeMethod<void>('ackCrash', {'crash_id': nativeId});
            return;
          }
          final milliseconds =
              extra?['occurred_at_ms'] ?? extra?['exit_timestamp_ms'];
          final persisted =
              await (debugPersistCrash ?? FastTracker.persistCrash)(
            name,
            eventId: nativeId,
            properties: properties,
            timestamp: milliseconds is num
                ? DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt())
                : null,
            sessionId: extra?['original_session_id'] as String?,
          );
          if (!persisted) return;
          _persistedNativeIds.add(nativeId);
          if (_persistedNativeIds.length > 256) {
            _persistedNativeIds.remove(_persistedNativeIds.first);
          }
          await _nativeMethod
              .invokeMethod<void>('ackCrash', {'crash_id': nativeId});
          if (fatal) unawaited(FastTracker.tracker.flush());
        } else {
          await FastTrackMcpDetectSink.track(name,
              properties: properties, flush: fatal);
        }
      } catch (e) {
        debugPrint('[ftm] crash report failed: $e');
      }
    }, zoneValues: {_reportZoneKey: true});
  }

  static Map<String, dynamic> _properties({
    required String source,
    required Object error,
    required StackTrace? stack,
    required bool fatal,
    String? message,
    String? library,
    String? context,
    String? exceptionType,
    String? thread,
    Map<String, dynamic>? extra,
  }) {
    final resolvedMessage =
        _clip(message ?? _messageOf(error), _maxMessageLength);
    final props = <String, dynamic>{
      if (extra != null) ...extra,
      'type': source,
      'exception': resolvedMessage,
      'exception_type':
          _clip(exceptionType ?? error.runtimeType.toString(), 256),
      'message': resolvedMessage,
      'stack': _clip(stack?.toString() ?? '', _maxStackLength),
      'thread': (thread == null || thread.isEmpty) ? _threadName() : thread,
      'is_fatal': fatal,
    };
    if (library != null && library.isNotEmpty) props['library'] = library;
    if (context != null && context.isNotEmpty) props['context'] = context;
    props.removeWhere((_, value) => value == null);
    return props;
  }

  static String _messageOf(Object error) {
    if (error is FlutterError) return error.message;
    return error.toString();
  }

  static String _threadName() {
    final name = Isolate.current.debugName;
    if (name == null || name.isEmpty) return 'main';
    return name;
  }

  static bool _isDuplicate(Object error, StackTrace? stack) {
    final stackText = stack?.toString() ?? '';
    final head =
        stackText.length <= 240 ? stackText : stackText.substring(0, 240);
    final key = '${error.runtimeType}|$error|$head';
    final now = DateTime.now();
    _recentErrors.removeWhere((_, at) => now.difference(at) >= _dedupWindow);
    if (_recentErrors.containsKey(key)) return true;
    if (_recentErrors.length >= 128) {
      _recentErrors.remove(_recentErrors.keys.first);
    }
    _recentErrors[key] = now;
    return false;
  }

  static bool _isBindingInitialized() {
    try {
      WidgetsBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _clip(String value, int max) {
    if (value.length <= max) return value;
    return value.substring(0, max);
  }
}
