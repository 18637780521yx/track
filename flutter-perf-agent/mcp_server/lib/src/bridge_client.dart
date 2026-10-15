import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

class BridgeClient {
  BridgeClient(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final PerfAgentConfig config;
  final http.Client _client;

  Uri _u(String path) => Uri.parse('${config.bridgeBaseUrl}$path');

  Future<Map<String, dynamic>> health() => _get('/health');

  Future<Map<String, dynamic>> startSession({
    required String testName,
    String? sessionId,
    int? waitStableMs,
  }) {
    return _post('/session/start', {
      'testName': testName,
      if (sessionId != null) 'sessionId': sessionId,
      'waitStableMs': waitStableMs ?? config.waitStableMs,
    });
  }

  Future<Map<String, dynamic>> stopSession() => _post('/session/stop', {});

  Future<Map<String, dynamic>> snapshot({bool raw = false}) =>
      _get('/snapshot${raw ? '?raw=1' : ''}');

  Future<Map<String, dynamic>> waitStable({int? waitStableMs}) {
    return _post('/wait', {
      'waitStableMs': waitStableMs ?? config.waitStableMs,
    });
  }

  Future<Map<String, dynamic>> ui() => _get('/ui');

  /// Legacy Bridge tap (in-app UiActions). Prefer flutter_skill via MCP.
  Future<Map<String, dynamic>> tapLegacy({
    required String targetDesc,
    int? waitStableMs,
  }) {
    return _post('/tap', {
      'targetDesc': targetDesc,
      'waitStableMs': waitStableMs ?? config.waitStableMs,
    });
  }

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      final res = await _client
          .get(_u(path))
          .timeout(const Duration(seconds: 10));
      return _decode(res);
    } catch (e) {
      return {
        'ok': false,
        'error': 'bridge unreachable: $e',
        'hint':
            'Start example_app with flutter run --profile, ensure PerfAgent bridge on ${config.bridgeBaseUrl}',
      };
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final res = await _client
          .post(
            _u(path),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      return _decode(res);
    } catch (e) {
      return {
        'ok': false,
        'error': 'bridge unreachable: $e',
        'hint':
            'Start example_app with flutter run --profile, ensure PerfAgent bridge on ${config.bridgeBaseUrl}',
      };
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return {'ok': false, 'error': 'unexpected response', 'body': res.body};
    } catch (e) {
      return {
        'ok': false,
        'error': 'invalid json (${res.statusCode}): $e',
        'body': res.body,
      };
    }
  }

  void close() => _client.close();
}
