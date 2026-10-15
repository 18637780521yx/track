import 'dart:io' as io;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Thin VM-service client that calls flutter_skill App extensions.
class FlutterSkillVmClient {
  FlutterSkillVmClient(
    this.wsUri, {
    this.maxRetries = 2,
    this.retryDelayMs = 300,
    this.debugLog = false,
  });

  final String wsUri;
  final int maxRetries;
  final int retryDelayMs;
  final bool debugLog;

  VmService? _service;
  String? _isolateId;

  static String normalizeWsUri(String raw) {
    var uri = raw.trim();
    if (uri.startsWith('http://')) {
      uri = uri.replaceFirst('http://', 'ws://');
    }
    if (uri.startsWith('https://')) {
      uri = uri.replaceFirst('https://', 'wss://');
    }
    if (!uri.endsWith('/ws')) {
      uri = uri.endsWith('/') ? '${uri}ws' : '$uri/ws';
    }
    return uri;
  }

  void _log(String msg) {
    if (debugLog) {
      io.stderr.writeln('[flutter_skill_vm] $msg');
    }
  }

  bool get isConnected => _service != null && _isolateId != null;

  Future<void> connect() async {
    if (isConnected) return;
    _service = await vmServiceConnectUri(wsUri);
    final vm = await _service!.getVM();
    final isolates = vm.isolates;
    if (isolates == null || isolates.isEmpty) {
      throw StateError('No Dart isolates at $wsUri');
    }
    final main = isolates.cast<IsolateRef?>().firstWhere(
          (i) => i?.name?.contains('main') == true,
          orElse: () => isolates.first,
        );
    _isolateId = main!.id;
    _log('connected isolate=$_isolateId');
  }

  /// Reconnect if the previous session dropped (hot restart / isolate recycle).
  Future<void> ensureConnected() async {
    if (!isConnected) {
      await connect();
      return;
    }
    try {
      await _service!.getVM();
    } catch (_) {
      await disconnect();
      await connect();
    }
  }

  Future<void> disconnect() async {
    try {
      await _service?.dispose();
    } catch (_) {}
    _service = null;
    _isolateId = null;
  }

  Future<Map<String, dynamic>> tap({
    String? text,
    String? key,
    String? ref,
  }) {
    return _withRetry('tap', () async {
      if (text == null && key == null && ref == null) {
        throw ArgumentError('tap requires text, key, or ref');
      }
      if (text != null) {
        final byText = await _call('ext.flutter.flutter_skill.tap', {
          'text': text,
        });
        if (_ok(byText)) return {...byText, 'matchedBy': 'text'};
        if (key == null && ref == null) return byText;
      }
      if (key != null) {
        final byKey = await _call('ext.flutter.flutter_skill.tap', {
          'key': key,
        });
        if (_ok(byKey)) return {...byKey, 'matchedBy': 'key'};
        if (ref == null && text == null) return byKey;
      }
      if (ref != null) {
        final byRef = await _call('ext.flutter.flutter_skill.tap', {
          'ref': ref,
        });
        return {...byRef, 'matchedBy': 'ref'};
      }
      if (text != null) {
        final asKey = await _call('ext.flutter.flutter_skill.tap', {
          'key': text,
        });
        return {...asKey, 'matchedBy': 'key_fallback'};
      }
      return {'success': false, 'error': 'tap failed'};
    });
  }

  Future<Map<String, dynamic>> enterText({
    required String text,
    String? target,
    String? key,
    String? ref,
  }) {
    return _withRetry('enterText', () async {
      final params = <String, String>{'text': text};
      // Prefer key for ValueKey fields; also try text label as key/text.
      if (key != null) {
        params['key'] = key;
      } else if (target != null) {
        params['key'] = target;
      }
      if (ref != null) params['ref'] = ref;

      var result = await _call('ext.flutter.flutter_skill.enterText', params);
      if (_ok(result)) return {...result, 'matchedBy': 'key'};

      // Retry treating target as visible text focus then type — tap first.
      if (target != null) {
        await _call('ext.flutter.flutter_skill.tap', {'text': target});
        result = await _call('ext.flutter.flutter_skill.enterText', {
          'text': text,
        });
        if (_ok(result)) return {...result, 'matchedBy': 'focus_then_type'};

        result = await _call('ext.flutter.flutter_skill.enterText', {
          'text': text,
          'key': target,
        });
      }
      return result;
    });
  }

  /// Scroll until [target] is visible (flutter_skill scroll_to).
  Future<Map<String, dynamic>> scrollTo({String? key, String? text}) {
    return _withRetry('scrollTo', () async {
      final params = <String, String>{};
      if (key != null) params['key'] = key;
      if (text != null) params['text'] = text;
      if (params.isEmpty) {
        throw ArgumentError('scrollTo requires key or text');
      }
      return _call('ext.flutter.flutter_skill.scroll', params);
    });
  }

  /// Directional swipe (up/down/left/right).
  Future<Map<String, dynamic>> swipe({
    required String direction,
    double distance = 300,
    String? key,
  }) {
    return _withRetry('swipe', () async {
      return _call('ext.flutter.flutter_skill.swipe', {
        'direction': direction,
        'distance': distance.toString(),
        if (key != null) 'key': key,
      });
    });
  }

  Future<Map<String, dynamic>> inspectInteractive() {
    return _withRetry(
      'inspect',
      () => _call('ext.flutter.flutter_skill.inspectInteractive', {}),
    );
  }

  /// Returns PNG/JPEG base64 from flutter_skill screenshot extension.
  Future<String?> screenshotBase64({int maxWidth = 720}) async {
    final result = await _withRetry('screenshot', () async {
      return _call('ext.flutter.flutter_skill.screenshot', {
        'quality': '0.65',
        'maxWidth': maxWidth.toString(),
      });
    });
    final image = result['image'];
    if (image is String && image.isNotEmpty) return image;
    return null;
  }

  Future<Map<String, dynamic>> _withRetry(
    String label,
    Future<Map<String, dynamic>> Function() action,
  ) async {
    Object? lastError;
    Map<String, dynamic>? lastResult;
    final attempts = maxRetries + 1;
    for (var i = 0; i < attempts; i++) {
      try {
        _log('$label attempt ${i + 1}/$attempts');
        final result = await action();
        lastResult = result;
        if (_ok(result)) {
          return {...result, 'attempts': i + 1};
        }
        lastError = result['error'] ?? 'action not ok';
      } catch (e) {
        lastError = e;
        _log('$label error: $e');
      }
      if (i < attempts - 1) {
        await Future<void>.delayed(Duration(milliseconds: retryDelayMs));
      }
    }
    return {
      'success': false,
      'error': lastError?.toString() ?? 'unknown',
      'lastResult': lastResult,
      'attempts': attempts,
    };
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, String> params,
  ) async {
    final service = _service;
    final isolateId = _isolateId;
    if (service == null || isolateId == null) {
      throw StateError('FlutterSkillVmClient not connected');
    }

    final response = await service.callServiceExtension(
      method,
      isolateId: isolateId,
      args: params,
    );

    final json = response.json;
    if (json == null) return {'success': false, 'error': 'empty response'};
    return Map<String, dynamic>.from(json);
  }

  static bool isOk(Map<String, dynamic> result) {
    if (result['success'] == true || result['ok'] == true) return true;
    final err = result['error'];
    return err == null && result.isNotEmpty && result['success'] != false;
  }

  static bool _ok(Map<String, dynamic> result) => isOk(result);
}
