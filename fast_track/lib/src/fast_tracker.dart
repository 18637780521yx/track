import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fast_tools/fast_tools.dart';
import 'package:fast_track/fast_track.dart';
import 'package:fast_track/src/event/objectbox_storage.dart';
import 'package:uuid/uuid.dart';

import 'utils/auto_properties.dart';
import 'utils/log.dart';
import 'utils/storage.dart';

class FastTracker {
  static final FastTracker tracker = FastTracker._internal();

  FastTracker._internal();

  final Map<String, dynamic> _commonProperties = {};

  SessionInfo? _session;

  TrackerConfig _config = const TrackerConfig();
  EventUploader? _uploader;

  bool _initialized = false;
  bool _initializing = false;
  bool _flushing = false;
  bool _optedOut = false;

  String? _distinctId;
  late String _anonymousId;

  final List<({String name, Map<String, dynamic> properties})> _preInitBuffer = [];

  DateTime? _lastRetryExhaustedAt;

  Timer? _flushTimer;

  static final _uuid = Uuid();

  static Future<void> init({
    String? url,
    Map<String, dynamic>? headers,
    DioBodyBuilder? bodyBuilder,
    EventUploader? uploader,
    TrackerConfig config = const TrackerConfig(),
    Map<String, dynamic> initialCommonProperties = const {},
  }) async {
    await tracker._init(
        url: url,
        headers: headers,
        bodyBuilder: bodyBuilder,
        uploader: uploader,
        config: config,
        initialCommonProperties: initialCommonProperties);
  }

  /// 初始化
  ///
  /// [url] 上报地址（使用内置 Dio uploader 时必需）
  /// [uploader] 自定义上传函数，传入后忽略 [url]/[headers]/[bodyBuilder]，可对接非 HTTP 通道
  Future<void> _init({
    String? url,
    Map<String, dynamic>? headers,
    DioBodyBuilder? bodyBuilder,
    EventUploader? uploader,
    TrackerConfig config = const TrackerConfig(),
    Map<String, dynamic> initialCommonProperties = const {},
  }) async {
    if (_initialized) {
      fastLog('init already done, skip');
      return;
    }

    if (_initializing) {
      fastLog('init already in progress, skip');
      return;
    }
    _initializing = true;

    try {
      fastLog('init start', debug: true);

      await FastTools.init();
      await FastStorage.init();

      _config = config;

      if (uploader != null) {
        _uploader = uploader;
      } else {
        assert(url != null, 'url is required when uploader is not provided');
        _uploader = createDioEventUploader(
          url: url!,
          headers: headers,
          bodyBuilder: bodyBuilder,
          config: _config,
        );
      }

      _commonProperties
        ..clear()
        ..addAll(initialCommonProperties);

      await _loadFromStorage();
      _ensureSession(forceNew: _session == null);

      _flushTimer?.cancel();
      _flushTimer = Timer.periodic(_config.flushInterval, (_) {
        _flush();
      });

      registerCommonProperties(AutoProperties.staticProperties);

      _initialized = true;

      if (_preInitBuffer.isNotEmpty) {
        fastLog('replaying ${_preInitBuffer.length} pre-init events', debug: true);
        final buffered = List.of(_preInitBuffer);
        _preInitBuffer.clear();
        for (final item in buffered) {
          await _track(item.name, properties: item.properties);
        }
      }

      final eventCount = FastStorage.getEventCount();
      fastLog('init done, events=$eventCount', debug: true);
    } finally {
      _initializing = false;
    }
  }

  // --- 用户身份管理 ---

  void identify(String userId) {
    if (userId.isEmpty) {
      fastLog('identify called with empty userId, ignored');
      return;
    }
    _distinctId = userId;
    Storage.setDistinctId(userId);
    fastLog('identify: $userId', debug: true);
  }

  void resetIdentity() {
    _distinctId = null;
    Storage.setDistinctId(null);
    _anonymousId = _generateRandomId();
    Storage.setAnonymousId(_anonymousId);
    fastLog('identity reset, new anonymousId=$_anonymousId', debug: true);
  }

  String? get distinctId => _distinctId;
  String get anonymousId => _anonymousId;

  // --- 隐私合规 ---

  void setOptOut(bool value) {
    _optedOut = value;
    Storage.setOptOut(value);
    fastLog('optOut set to $value');
  }

  bool get isOptedOut => _optedOut;

  // --- 公共属性 ---

  void registerCommonProperties(Map<String, dynamic> props) {
    _commonProperties.addAll(props);
    _saveCommonProperties();
  }

  void unregisterCommonProperties(List<String> keys) {
    for (final key in keys) {
      _commonProperties.remove(key);
    }
    _saveCommonProperties();
  }

  Map<String, dynamic> get commonProperties => Map.unmodifiable(_commonProperties);

  TrackerConfig get config => _config;

  void onForeground() {
    _ensureSession(forceNew: true);
  }

  static Future<void> track(String name, {Map<String, dynamic> properties = const {}}) async =>
      tracker._track(name, properties: properties);

  Future<void> _track(
    String name, {
    Map<String, dynamic> properties = const {},
  }) async {
    if (_optedOut) return;

    if (name.isEmpty) {
      fastLog('track called with empty name, ignored');
      return;
    }

    if (!_initialized) {
      fastLog('EventTracker not initialized, buffering event: $name');
      _preInitBuffer.add((name: name, properties: Map<String, dynamic>.from(properties)));
      return;
    }

    try {
      final now = DateTime.now();

      _ensureSession();

      final event = TrackEvent.fromMaps(
        id: _generateRandomId(),
        name: name,
        properties: properties,
        commonProperties: {
          ...Map<String, dynamic>.from(_commonProperties),
          ...AutoProperties.dynamicProperties,
        },
        distinctId: _distinctId,
        anonymousId: _anonymousId,
        sessionId: _session!.id,
        timestamp: now,
      );

      await FastStorage.appendEvent(event);

      final eventCount = FastStorage.getEventCount();

      if (!_flushing && eventCount > _config.maxCachedEvents) {
        final deleteCount = eventCount - _config.maxCachedEvents;
        await FastStorage.deleteOldestEvents(deleteCount);
        fastLog('maxCachedEvents exceeded, deleted $deleteCount oldest events', debug: true);
      }

      fastLog('track: $name, properties=${jsonEncode(properties)}, total=$eventCount', debug: true);

      if (eventCount >= _config.maxBatchSize) {
        unawaited(_flush());
      }
    } catch (e) {
      fastLog('track failed: $name', error: e);
    }
  }

  Future<void> flush() async {
    await _flush();
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
    FastStorage.close();
  }

  // ------ 内部实现 ------

  void _ensureSession({bool forceNew = false}) {
    final now = DateTime.now();

    if (!forceNew && _session != null) {
      final diff = now.difference(_session!.lastActiveAt);
      if (diff < _config.sessionTimeout) {
        _session = _session!.copyWith(lastActiveAt: now);
        return;
      }
    }

    _session = SessionInfo(
      id: _generateRandomId(),
      lastActiveAt: now,
    );
    _saveSession();
  }

  Future<void> _loadFromStorage() async {
    final common = Storage.loadCommonProperties();
    _commonProperties
      ..clear()
      ..addAll(common);

    _session = Storage.loadSession();
    _optedOut = Storage.optOut;
    _distinctId = Storage.getDistinctId();

    final savedAnonymousId = Storage.getAnonymousId();
    if (savedAnonymousId != null) {
      _anonymousId = savedAnonymousId;
    } else {
      _anonymousId = _generateRandomId();
      Storage.setAnonymousId(_anonymousId);
      fastLog('generated new anonymousId=$_anonymousId', debug: true);
    }
  }

  Future<void> _saveCommonProperties() async {
    await Storage.saveCommonProperties(_commonProperties);
  }

  Future<void> _saveSession() async {
    try {
      await Storage.saveSession(_session);
    } catch (e) {
      fastLog('saveSession failed', error: e);
      rethrow;
    }
  }

  bool get _isNetworkAvailable {
    try {
      return FastConnectivity.currentStatus != FastNetworkStatus.none;
    } catch (_) {
      return true;
    }
  }

  Future<void> _flush() async {
    if (_optedOut) return;
    if (_flushing) return;
    if (_uploader == null) return;

    if (FastStorage.getEventCount() == 0) return;

    if (_config.checkNetworkBeforeFlush && !_isNetworkAvailable) {
      fastLog('flush skip: no network', debug: true);
      return;
    }

    final now = DateTime.now();
    if (_lastRetryExhaustedAt != null) {
      final elapsed = now.difference(_lastRetryExhaustedAt!);
      if (elapsed < _config.retryCoolOffDuration) {
        fastLog(
            'flush skip: in cool-off (${_config.retryCoolOffDuration.inMinutes}min), ${(_config.retryCoolOffDuration.inSeconds - elapsed.inSeconds)}s left',
            debug: true);
        return;
      }
      _lastRetryExhaustedAt = null;
    }

    _flushing = true;
    int sentCount = 0;
    int failedCount = 0;
    int droppedCount = 0;
    String? lastError;

    try {
      while (true) {
        final remaining = FastStorage.getEventCount();
        if (remaining == 0) break;

        final batchSize = min(_config.maxBatchSize, remaining);
        final events = await FastStorage.loadEvents(limit: batchSize);

        if (events.isEmpty) break;

        fastLog('flush batch=$batchSize, remaining=$remaining', debug: true);

        if (_config.dryRun) {
          fastLog('DRY RUN: would send ${events.length} events:');
          for (var i = 0; i < events.length; i++) {
            fastLog('  [$i] ${events[i].name} ${jsonEncode(events[i].properties)}');
          }
          final eventIds = events.map((e) => e.id).toList();
          await FastStorage.deleteEvents(eventIds);
          sentCount += events.length;
          continue;
        }

        if (_config.enableDebugLog) {
          for (var i = 0; i < events.length; i++) {
            fastLog('payload[$i] ${jsonEncode(events[i].toJson())}', debug: true);
          }
        }

        final result = await _uploader!(events);

        if (result.success) {
          final eventIds = events.map((e) => e.id).toList();
          await FastStorage.deleteEvents(eventIds);
          sentCount += events.length;
          fastLog('flush success, sent ${events.length}', debug: true);
        } else if (!result.shouldRetry) {
          fastLog(
            'upload failed non-retryable, drop batch (${events.length}). '
            'code=${result.statusCode} msg=${result.message}',
          );
          lastError = result.message;
          final eventIds = events.map((e) => e.id).toList();
          await FastStorage.deleteEvents(eventIds);
          droppedCount += events.length;
        } else {
          _lastRetryExhaustedAt = DateTime.now();
          failedCount += events.length;
          lastError = result.message;
          fastLog(
            'upload failed after retries, keep batch (${events.length}), cool-off ${_config.retryCoolOffDuration.inMinutes}min',
          );
          break;
        }
      }
    } catch (e, st) {
      lastError = e.toString();
      fastLog('flush error: $e', error: e);
      fastLog(st.toString());
    } finally {
      _flushing = false;

      try {
        final remaining = FastStorage.getEventCount();
        if (remaining > _config.maxCachedEvents) {
          final deleteCount = remaining - _config.maxCachedEvents;
          await FastStorage.deleteOldestEvents(deleteCount);
          fastLog('post-flush overflow cleanup, deleted $deleteCount oldest events', debug: true);
        }
      } catch (e) {
        fastLog('post-flush overflow cleanup failed', error: e);
      }

      if (_config.onFlushResult != null && (sentCount > 0 || failedCount > 0 || droppedCount > 0)) {
        _config.onFlushResult!(FlushResult(
          sentCount: sentCount,
          failedCount: failedCount,
          droppedCount: droppedCount,
          lastError: lastError,
        ));
      }
    }
  }

  String _generateRandomId() {
    return _uuid.v4();
  }
}
