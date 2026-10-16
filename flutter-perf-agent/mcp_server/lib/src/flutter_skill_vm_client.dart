import 'dart:io' as io;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'flutter_skill_client.dart';

/// 基于 [VmService] 的 [FlutterSkillClient] 实现。
///
/// 连接 App 的 Observatory / VM Service WebSocket，在 main isolate 上调用
/// `ext.flutter.flutter_skill.*`。带有限次重试与断线重连。
class FlutterSkillVmClient implements FlutterSkillClient {
  FlutterSkillVmClient(
    this.wsUri, {
    this.maxRetries = 2,
    this.retryDelayMs = 300,
    this.debugLog = false,
  });

  @override
  final String wsUri;

  /// 动作失败时的额外重试次数（总尝试 = [maxRetries] + 1）。
  final int maxRetries;

  /// 两次尝试之间的间隔毫秒。
  final int retryDelayMs;

  /// 是否向 stderr 打印调试日志。
  final bool debugLog;

  VmService? _service;
  String? _isolateId;

  /// 底层 VM Service（只读暴露，供调试）。
  VmService? get service => _service;

  /// 当前选中的 isolate id。
  String? get isolateId => _isolateId;

  /// 将 `http(s)://…` 规范为 `ws(s)://…/ws`。
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

  /// 判断 flutter_skill 扩展返回是否成功。
  static bool isOk(Map<String, dynamic> result) {
    if (result['success'] == true || result['ok'] == true) return true;
    final err = result['error'];
    return err == null && result.isNotEmpty && result['success'] != false;
  }

  void _log(String msg) {
    if (debugLog) {
      io.stderr.writeln('[flutter_skill_vm] $msg');
    }
  }

  @override
  bool get isConnected => _service != null && _isolateId != null;

  @override
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

  @override
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

  @override
  Future<void> disconnect() async {
    try {
      await _service?.dispose();
    } catch (_) {}
    _service = null;
    _isolateId = null;
  }

  @override
  Future<Map<String, dynamic>> callExtension(
    String method, [
    Map<String, String>? params,
  ]) =>
      _call(method, params ?? const {});

  // ── 基础手势 / 输入 ──────────────────────────────────────────────────

  @override
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
        if (isOk(byText)) return {...byText, 'matchedBy': 'text'};
        if (key == null && ref == null) return byText;
      }
      if (key != null) {
        final byKey = await _call('ext.flutter.flutter_skill.tap', {
          'key': key,
        });
        if (isOk(byKey)) return {...byKey, 'matchedBy': 'key'};
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

  @override
  Future<Map<String, dynamic>> enterText({
    required String text,
    String? target,
    String? key,
    String? ref,
  }) {
    return _withRetry('enterText', () async {
      final params = <String, String>{'text': text};
      if (key != null) {
        params['key'] = key;
      } else if (target != null) {
        params['key'] = target;
      }
      if (ref != null) params['ref'] = ref;

      var result = await _call('ext.flutter.flutter_skill.enterText', params);
      if (isOk(result)) return {...result, 'matchedBy': 'key'};

      // Key 失败：先按可见文本 tap 聚焦，再 type。
      if (target != null) {
        await _call('ext.flutter.flutter_skill.tap', {'text': target});
        result = await _call('ext.flutter.flutter_skill.enterText', {
          'text': text,
        });
        if (isOk(result)) return {...result, 'matchedBy': 'focus_then_type'};

        result = await _call('ext.flutter.flutter_skill.enterText', {
          'text': text,
          'key': target,
        });
      }
      return result;
    });
  }

  @override
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

  @override
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

  @override
  Future<Map<String, dynamic>> inspectInteractive() {
    return _withRetry(
      'inspect',
      () => _call('ext.flutter.flutter_skill.inspectInteractive', {}),
    );
  }

  @override
  Future<String?> screenshotBase64({int maxWidth = 720}) async {
    final result = await screenshot(maxWidth: maxWidth);
    final image = result['image'];
    if (image is String && image.isNotEmpty) return image;
    return null;
  }

  @override
  Future<Map<String, dynamic>> screenshot({
    double quality = 0.65,
    int maxWidth = 720,
  }) {
    return _withRetry(
      'screenshot',
      () => _call('ext.flutter.flutter_skill.screenshot', {
            'quality': quality.toString(),
            'maxWidth': maxWidth.toString(),
          }),
    );
  }

  // ── 检查 / 查找 ──────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> interactive({bool includePositions = true}) {
    return _withRetry(
      'interactive',
      () => _call('ext.flutter.flutter_skill.interactive', {
            'includePositions': includePositions.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> interactiveStructured() {
    return _withRetry(
      'interactiveStructured',
      () => _call('ext.flutter.flutter_skill.interactiveStructured', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getWidgetTree({int maxDepth = 10}) {
    return _withRetry(
      'getWidgetTree',
      () => _call('ext.flutter.flutter_skill.getWidgetTree', {
            'maxDepth': maxDepth.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> getWidgetProperties(String key) {
    return _withRetry(
      'getWidgetProperties',
      () => _call('ext.flutter.flutter_skill.getWidgetProperties', {
            'key': key,
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> getTextContent() {
    return _withRetry(
      'getTextContent',
      () => _call('ext.flutter.flutter_skill.getTextContent', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> findByType(String type) {
    return _withRetry(
      'findByType',
      () => _call('ext.flutter.flutter_skill.findByType', {'type': type}),
    );
  }

  // ── 进阶手势 ─────────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> longPress({
    String? key,
    String? text,
    String? ref,
    int durationMs = 500,
  }) {
    return _withRetry(
      'longPress',
      () => _call('ext.flutter.flutter_skill.longPress', {
            if (key != null) 'key': key,
            if (text != null) 'text': text,
            if (ref != null) 'ref': ref,
            'duration': durationMs.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> doubleTap({
    String? key,
    String? text,
    String? ref,
  }) {
    return _withRetry(
      'doubleTap',
      () => _call('ext.flutter.flutter_skill.doubleTap', {
            if (key != null) 'key': key,
            if (text != null) 'text': text,
            if (ref != null) 'ref': ref,
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> drag({
    required String fromKey,
    required String toKey,
    int holdMs = 0,
  }) {
    return _withRetry(
      'drag',
      () => _call('ext.flutter.flutter_skill.drag', {
            'fromKey': fromKey,
            'toKey': toKey,
            'hold': holdMs.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> pressKey(
    String key, {
    List<String>? modifiers,
  }) {
    return _withRetry(
      'pressKey',
      () => _call('ext.flutter.flutter_skill.pressKey', {
            'key': key,
            if (modifiers != null && modifiers.isNotEmpty)
              'modifiers': modifiers.join(','),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> typeText(String text) {
    return _withRetry(
      'typeText',
      () => _call('ext.flutter.flutter_skill.typeText', {'text': text}),
    );
  }

  @override
  Future<Map<String, dynamic>> focus(String key) {
    return _withRetry(
      'focus',
      () => _call('ext.flutter.flutter_skill.focus', {'key': key}),
    );
  }

  @override
  Future<Map<String, dynamic>> blur({String? key}) {
    return _withRetry(
      'blur',
      () => _call('ext.flutter.flutter_skill.blur', {
            if (key != null) 'key': key,
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> setCheckbox(String key, bool checked) {
    return _withRetry(
      'setCheckbox',
      () => _call('ext.flutter.flutter_skill.setCheckbox', {
            'key': key,
            'checked': checked.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> hover({String? key, String? text}) {
    return _withRetry(
      'hover',
      () => _call('ext.flutter.flutter_skill.hover', {
            if (key != null) 'key': key,
            if (text != null) 'text': text,
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> tapAt({required double x, required double y}) {
    return _withRetry(
      'tapAt',
      () => _call('ext.flutter.flutter_skill.tapAt', {
            'x': x.toString(),
            'y': y.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> longPressAt({
    required double x,
    required double y,
    int durationMs = 500,
  }) {
    return _withRetry(
      'longPressAt',
      () => _call('ext.flutter.flutter_skill.longPressAt', {
            'x': x.toString(),
            'y': y.toString(),
            'duration': durationMs.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> swipeCoordinates({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    int durationMs = 300,
    int holdMs = 0,
  }) {
    return _withRetry(
      'swipeCoordinates',
      () => _call('ext.flutter.flutter_skill.swipeCoordinates', {
            'startX': startX.toString(),
            'startY': startY.toString(),
            'endX': endX.toString(),
            'endY': endY.toString(),
            'duration': durationMs.toString(),
            'hold': holdMs.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> edgeSwipe({
    required String edge,
    required String direction,
    double distance = 200,
  }) {
    return _withRetry(
      'edgeSwipe',
      () => _call('ext.flutter.flutter_skill.edgeSwipe', {
            'edge': edge,
            'direction': direction,
            'distance': distance.toString(),
          }),
    );
  }

  // ── 等待 / 表单状态 ──────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> waitForElement({
    String? key,
    String? text,
    int timeoutMs = 5000,
  }) {
    return _withRetry(
      'waitForElement',
      () => _call('ext.flutter.flutter_skill.waitForElement', {
            if (key != null) 'key': key,
            if (text != null) 'text': text,
            'timeout': timeoutMs.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> waitForGone({
    String? key,
    String? text,
    int timeoutMs = 5000,
  }) {
    return _withRetry(
      'waitForGone',
      () => _call('ext.flutter.flutter_skill.waitForGone', {
            if (key != null) 'key': key,
            if (text != null) 'text': text,
            'timeout': timeoutMs.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> getTextValue({String? key}) {
    return _withRetry(
      'getTextValue',
      () => _call('ext.flutter.flutter_skill.getTextValue', {
            if (key != null) 'key': key,
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> getCheckboxState(String key) {
    return _withRetry(
      'getCheckboxState',
      () => _call('ext.flutter.flutter_skill.getCheckboxState', {'key': key}),
    );
  }

  @override
  Future<Map<String, dynamic>> getSliderValue(String key) {
    return _withRetry(
      'getSliderValue',
      () => _call('ext.flutter.flutter_skill.getSliderValue', {'key': key}),
    );
  }

  // ── 截图 / 导航 ──────────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> screenshotRegion({
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    return _withRetry(
      'screenshotRegion',
      () => _call('ext.flutter.flutter_skill.screenshotRegion', {
            'x': x.toString(),
            'y': y.toString(),
            'width': width.toString(),
            'height': height.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> screenshotElement(String key) {
    return _withRetry(
      'screenshotElement',
      () => _call('ext.flutter.flutter_skill.screenshotElement', {'key': key}),
    );
  }

  @override
  Future<Map<String, dynamic>> getCurrentRoute() {
    return _withRetry(
      'getCurrentRoute',
      () => _call('ext.flutter.flutter_skill.getCurrentRoute', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> goBack() {
    return _withRetry(
      'goBack',
      () => _call('ext.flutter.flutter_skill.goBack', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getNavigationStack() {
    return _withRetry(
      'getNavigationStack',
      () => _call('ext.flutter.flutter_skill.getNavigationStack', {}),
    );
  }

  // ── 指示器 / 日志 / 辅助指标 ─────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> enableIndicators({String style = 'standard'}) {
    return _withRetry(
      'enableIndicators',
      () => _call('ext.flutter.flutter_skill.enableIndicators', {
            'style': style,
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> disableIndicators() {
    return _withRetry(
      'disableIndicators',
      () => _call('ext.flutter.flutter_skill.disableIndicators', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getIndicatorStatus() {
    return _withRetry(
      'getIndicatorStatus',
      () => _call('ext.flutter.flutter_skill.getIndicatorStatus', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getLogs() {
    return _withRetry(
      'getLogs',
      () => _call('ext.flutter.flutter_skill.getLogs', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getErrors() {
    return _withRetry(
      'getErrors',
      () => _call('ext.flutter.flutter_skill.getErrors', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> clearLogs() {
    return _withRetry(
      'clearLogs',
      () => _call('ext.flutter.flutter_skill.clearLogs', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getPerformance() {
    return _withRetry(
      'getPerformance',
      () => _call('ext.flutter.flutter_skill.getPerformance', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getFrameStats() {
    return _withRetry(
      'getFrameStats',
      () => _call('ext.flutter.flutter_skill.getFrameStats', {}),
    );
  }

  @override
  Future<Map<String, dynamic>> getHttpRequests({
    int limit = 50,
    int offset = 0,
  }) {
    return _withRetry(
      'getHttpRequests',
      () => _call('ext.flutter.flutter_skill.getHttpRequests', {
            'limit': limit.toString(),
            'offset': offset.toString(),
          }),
    );
  }

  @override
  Future<Map<String, dynamic>> clearHttpRequests() {
    return _withRetry(
      'clearHttpRequests',
      () => _call('ext.flutter.flutter_skill.clearHttpRequests', {}),
    );
  }

  // ── 内部：重试 + 扩展调用 ─────────────────────────────────────────────

  /// 带断线重连的有限次重试包装。
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
        await ensureConnected();
        final result = await action();
        lastResult = result;
        if (isOk(result)) {
          return {...result, 'attempts': i + 1};
        }
        lastError = result['error'] ?? 'action not ok';
      } catch (e) {
        lastError = e;
        _log('$label error: $e');
        if (_isServiceGone(e)) {
          await disconnect();
        }
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

  static bool _isServiceGone(Object e) {
    final msg = e.toString();
    return msg.contains('Service has disappeared') ||
        msg.contains('Service connection disposed') ||
        msg.contains('not connected') ||
        msg.contains('Connection closed');
  }

  /// 在当前 isolate 上调用 service extension。
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
}
