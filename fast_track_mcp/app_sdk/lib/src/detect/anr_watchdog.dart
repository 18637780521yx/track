import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';

import 'detect_sink.dart';
import 'event_names.dart';

/// ANR / App Hang 监测。
///
/// - **Android / iOS**：原生插件（主线程 heartbeat / RunLoop stall + Android
///   `ApplicationExitInfo`），经 Method/EventChannel 上报 `app_anr`。
/// - **其它平台**：回退 Soft ANR（后台 Isolate ping UI Isolate）。
///
/// 主线程堵死时落库仍可能延后到 UI 恢复；原生侧可先抓住主线程 stack（Android）。
class FastTrackMcpAnrWatchdog {
  FastTrackMcpAnrWatchdog._();

  static const Duration _defaultTimeout = Duration(seconds: 5);
  static const _method = MethodChannel('fast_track_mcp/anr');
  static const _events = EventChannel('fast_track_mcp/anr_events');

  static Future<void>? _starting;
  static Future<void> _historicalTail = Future.value();
  static final Set<String> _persistedHistory = {};
  @visibleForTesting
  static Future<bool> Function(String id, Map<String, dynamic> properties)?
      debugPersistHistory;
  static bool _started = false;
  static String _mode = 'off';
  static Duration _timeout = _defaultTimeout;
  static bool _reporting = false;
  static DateTime? _lastReportAt;
  static Future<void> Function(Map<String, dynamic> properties)? _onAnr;
  static StreamSubscription<dynamic>? _eventSub;

  // Soft fallback (desktop / missing plugin)
  static Isolate? _isolate;
  static ReceivePort? _mainPort;
  static SendPort? _watchdogSendPort;
  static StreamSubscription<dynamic>? _mainSub;

  @visibleForTesting
  static Future<void> Function(String name, Map<String, dynamic> properties)?
      debugOnReport;

  static bool get isStarted => _started;
  static String get mode => _mode;

  static bool get _preferNative {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// 启动。Android/iOS 优先原生；失败或非移动端走 Soft Isolate。
  static Future<void> start({
    Duration timeout = _defaultTimeout,
    Future<void> Function(Map<String, dynamic> properties)? onAnr,
  }) {
    if (_started) return Future.value();
    return _starting ??=
        _start(timeout: timeout, onAnr: onAnr).whenComplete(() {
      _starting = null;
    });
  }

  static Future<void> _start(
      {required Duration timeout,
      Future<void> Function(Map<String, dynamic>)? onAnr}) async {
    if (timeout <= Duration.zero) {
      debugPrint('[ftm] ANR watchdog skipped: timeout must be > 0');
      return;
    }

    _timeout = timeout;
    _onAnr = onAnr;

    if (_preferNative) {
      final ok = await _startNative(timeout);
      if (ok) return;
      debugPrint('[ftm] native ANR unavailable → soft fallback');
    }
    await _startSoft(timeout);
  }

  static Future<bool> _startNative(Duration timeout) async {
    try {
      await _eventSub?.cancel();
      _eventSub = _events.receiveBroadcastStream().listen(
        (event) {
          if (event is! Map) return;
          final map = Map<Object?, Object?>.from(event);
          final type = map['event_type']?.toString();
          if (type != null && type != 'anr') return;
          unawaited(_emitAnr(map));
        },
        onError: (Object e) {
          debugPrint('[ftm] ANR event stream error: $e');
        },
      );
      final res = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'start',
        {'timeoutMs': timeout.inMilliseconds},
      );
      _started = true;
      _mode = res?['mode']?.toString() ?? 'native';
      debugPrint(
        '[ftm] ANR watchdog started mode=$_mode '
        '(timeout=${timeout.inMilliseconds}ms)',
      );
      return true;
    } on MissingPluginException {
      await _eventSub?.cancel();
      _eventSub = null;
      return false;
    } catch (e) {
      debugPrint('[ftm] native ANR start failed: $e');
      await _eventSub?.cancel();
      _eventSub = null;
      return false;
    }
  }

  static Future<void> _startSoft(Duration timeout) async {
    final mainPort = ReceivePort();
    _mainPort = mainPort;

    final ready = Completer<SendPort>();
    _mainSub = mainPort.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is int) {
        _watchdogSendPort?.send(message);
        return;
      }
      if (message is Map) {
        unawaited(_emitAnr(Map<Object?, Object?>.from(message)));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _anrWatchdogEntry,
        _AnrWatchdogSpawnArgs(
          mainSendPort: mainPort.sendPort,
          timeoutMs: timeout.inMilliseconds,
        ),
        debugName: 'fast-track-anr-watchdog',
        errorsAreFatal: false,
      );
      _watchdogSendPort = await ready.future.timeout(
        const Duration(seconds: 3),
      );
      _started = true;
      _mode = 'soft';
      debugPrint(
        '[ftm] ANR watchdog started mode=soft '
        '(timeout=${timeout.inMilliseconds}ms)',
      );
    } catch (e) {
      debugPrint('[ftm] soft ANR start failed: $e');
      await stop();
    }
  }

  static Future<void> stop() async {
    _started = false;
    _mode = 'off';

    try {
      if (_preferNative) {
        await _method.invokeMethod<void>('stop');
      }
    } catch (_) {}
    await _eventSub?.cancel();
    _eventSub = null;

    final isolate = _isolate;
    _isolate = null;
    isolate?.kill(priority: Isolate.immediate);
    await _mainSub?.cancel();
    _mainSub = null;
    _mainPort?.close();
    _mainPort = null;
    _watchdogSendPort = null;
    _onAnr = null;
    _reporting = false;
  }

  @visibleForTesting
  static Future<void> debugReset() async {
    await _starting;
    await stop();
    await _historicalTail;
    _persistedHistory.clear();
    debugPersistHistory = null;
    _lastReportAt = null;
    debugOnReport = null;
    _timeout = _defaultTimeout;
  }

  /// 测试用：直接注入一条 ANR 事件（不经原生 / Isolate）。
  @visibleForTesting
  static Future<void> debugEmit(Map<Object?, Object?> raw) => _emitAnr(raw);

  static Future<void> _emitAnr(Map<Object?, Object?> raw) async {
    final historicalId = raw['anr_id']?.toString();
    if (historicalId != null) {
      final task =
          _historicalTail.then((_) => _reportHistory(historicalId, raw));
      _historicalTail = task;
      await task;
      return;
    }
    if (_reporting) return;
    final now = DateTime.now();
    final cooldown = Duration(milliseconds: _timeout.inMilliseconds * 3);
    if (_lastReportAt != null && now.difference(_lastReportAt!) < cooldown) {
      return;
    }

    final blockedMs =
        (raw['blocked_ms'] as num?)?.toInt() ?? _timeout.inMilliseconds;
    final source = (raw['anr_source'] as String?) ?? _mode;
    final stack = raw['stack']?.toString() ?? '';
    final isFatal = raw['is_fatal'] == true;
    final platform = raw['platform']?.toString();

    _reporting = true;
    _lastReportAt = now;
    try {
      final properties = <String, dynamic>{
        'type': 'anr_watchdog',
        'exception_type': 'ApplicationNotResponding',
        'message': 'Main thread blocked for ${blockedMs}ms ($source)',
        'exception': 'Main thread blocked for ${blockedMs}ms ($source)',
        'stack': stack,
        'thread': 'main',
        'is_fatal': isFatal,
        'blocked_ms': blockedMs,
        'anr_source': source,
        if (platform != null) 'platform': platform,
        if (raw['exit_timestamp_ms'] != null)
          'exit_timestamp_ms': raw['exit_timestamp_ms'],
        if (raw['description'] != null) 'description': raw['description'],
        if (raw['tombstone'] != null) 'tombstone': raw['tombstone'],
        if (raw['tombstone_source'] != null)
          'tombstone_source': raw['tombstone_source'],
        if (raw['tombstone_path'] != null)
          'tombstone_path': raw['tombstone_path'],
      };

      final hook = debugOnReport;
      if (hook != null) {
        await hook(FastTrackMcpEventName.appAnr, properties);
        return;
      }

      await FastTrackMcpDetectSink.track(
        FastTrackMcpEventName.appAnr,
        properties: properties,
        flush: true,
      );

      final onAnr = _onAnr;
      if (onAnr != null) {
        await onAnr(properties);
      }
    } catch (e) {
      debugPrint('[ftm] ANR report failed: $e');
    } finally {
      _reporting = false;
    }
  }

  static Future<void> _reportHistory(
      String id, Map<Object?, Object?> raw) async {
    try {
      if (!_persistedHistory.contains(id)) {
        final props = <String, dynamic>{
          for (final entry in raw.entries)
            if (entry.key is String) entry.key as String: entry.value,
          'type': 'anr_watchdog',
          'exception_type': 'ApplicationNotResponding',
          'message': raw['description']?.toString() ?? 'Historical ANR',
          'thread': 'main',
          'is_fatal': true,
        };
        final timestamp = raw['exit_timestamp_ms'];
        final hook = debugPersistHistory;
        final persisted = hook != null
            ? await hook(id, props)
            : await FastTracker.persistCrash(
                FastTrackMcpEventName.appAnr,
                eventId: id,
                properties: props,
                timestamp: timestamp is num
                    ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt())
                    : null,
              );
        if (!persisted) return;
        _persistedHistory.add(id);
        if (_persistedHistory.length > 128) {
          _persistedHistory.remove(_persistedHistory.first);
        }
      }
      await _method.invokeMethod<void>('ackAnr', {'anr_id': id});
      if (debugPersistHistory == null) unawaited(FastTracker.tracker.flush());
    } catch (error, stack) {
      debugPrint('[ftm] historical ANR retained for retry: $error\n$stack');
    }
  }
}

class _AnrWatchdogSpawnArgs {
  const _AnrWatchdogSpawnArgs({
    required this.mainSendPort,
    required this.timeoutMs,
  });

  final SendPort mainSendPort;
  final int timeoutMs;
}

void _anrWatchdogEntry(_AnrWatchdogSpawnArgs args) {
  final ackPort = ReceivePort();
  args.mainSendPort.send(ackPort.sendPort);

  var lastAckId = 0;
  var pingId = 0;
  var lastReportAtMs = 0;
  var reporting = false;

  ackPort.listen((message) {
    if (message is int && message > lastAckId) {
      lastAckId = message;
    }
  });

  Future<void> loop() async {
    final timeout = Duration(milliseconds: args.timeoutMs);
    final cooldownMs = args.timeoutMs * 3;
    while (true) {
      pingId++;
      final id = pingId;
      args.mainSendPort.send(id);
      await Future<void>.delayed(timeout);
      if (lastAckId >= id) continue;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastReportAtMs <= cooldownMs) continue;
      if (reporting) continue;
      reporting = true;
      try {
        lastReportAtMs = now;
        args.mainSendPort.send(<String, Object>{
          'blocked_ms': args.timeoutMs,
          'anr_source': 'soft_watchdog',
          'stack': '',
          'is_fatal': false,
          'platform': 'dart',
        });
      } finally {
        reporting = false;
      }
    }
  }

  unawaited(loop());
}
