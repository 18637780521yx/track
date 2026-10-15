import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Thin VM-service client that calls flutter_skill App extensions.
///
/// UI actions belong to flutter_skill; this class only invokes them.
class FlutterSkillVmClient {
  FlutterSkillVmClient(this.wsUri);

  final String wsUri;
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

  Future<void> connect() async {
    _service = await vmServiceConnectUri(wsUri);
    final vm = await _service!.getVM();
    final isolates = vm.isolates;
    if (isolates == null || isolates.isEmpty) {
      throw StateError('No Dart isolates at $wsUri');
    }
    // Prefer the main isolate.
    final main = isolates.cast<IsolateRef?>().firstWhere(
          (i) => i?.name?.contains('main') == true,
          orElse: () => isolates.first,
        );
    _isolateId = main!.id;
  }

  Future<void> disconnect() async {
    try {
      await _service?.dispose();
    } catch (_) {}
    _service = null;
    _isolateId = null;
  }

  /// Tap via flutter_skill. Tries [text] first, then [key] if provided.
  Future<Map<String, dynamic>> tap({
    String? text,
    String? key,
    String? ref,
  }) async {
    if (text == null && key == null && ref == null) {
      throw ArgumentError('tap requires text, key, or ref');
    }

    // Prefer text for natural-language targets ("登录"), then key.
    if (text != null) {
      final byText = await _call('ext.flutter.flutter_skill.tap', {
        'text': text,
      });
      if (_ok(byText)) return {...byText, 'matchedBy': 'text'};
      // Fall through to key if text failed and key given.
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

    // Last attempt: treat the same string as key if only text was tried.
    if (text != null) {
      final asKey = await _call('ext.flutter.flutter_skill.tap', {
        'key': text,
      });
      return {...asKey, 'matchedBy': 'key_fallback'};
    }

    return {'success': false, 'error': 'tap failed'};
  }

  Future<Map<String, dynamic>> inspectInteractive() async {
    return _call('ext.flutter.flutter_skill.inspectInteractive', {});
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

    // Matches flutter_skill FlutterSkillClient: extension payload is response.json.
    final json = response.json;
    if (json == null) return {'success': false, 'error': 'empty response'};
    return Map<String, dynamic>.from(json);
  }

  static bool _ok(Map<String, dynamic> result) {
    if (result['success'] == true || result['ok'] == true) return true;
    final err = result['error'];
    return err == null && result.isNotEmpty && result['success'] != false;
  }
}
