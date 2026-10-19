import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Client for the local Python demo API (`example_app/server/app.py`).
///
/// Start server first:
///   python3 server/app.py
/// → http://127.0.0.1:18765
class DemoApi {
  DemoApi._(this.baseUrl);

  static DemoApi? _instance;
  static DemoApi get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('DemoApi.ensureReady() must run before use');
    }
    return i;
  }

  /// Override with `--dart-define=DEMO_API_BASE=http://10.0.2.2:18765` on Android emulator.
  static const String defaultBaseUrl = String.fromEnvironment(
    'DEMO_API_BASE',
    defaultValue: 'http://127.0.0.1:18765',
  );

  final String baseUrl;
  String? _token;

  String? get token => _token;

  Future<void> logout() async {
    final t = _token;
    _token = null;
    if (t == null || t.isEmpty) return;
    try {
      await _postJson('/api/logout', {'token': t}, bearer: t);
    } catch (_) {
      // Local session already cleared; ignore network errors on logout.
    }
  }

  /// Ping Python `/health`; throws if the server is not running.
  static Future<DemoApi> ensureReady({String? baseUrl}) async {
    if (_instance != null) return _instance!;
    final api = DemoApi._(baseUrl ?? defaultBaseUrl);
    await api._assertHealthy();
    _instance = api;
    return api;
  }

  Future<void> _assertHealthy() async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 2));
      final res = await req.close().timeout(const Duration(seconds: 2));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw StateError('demo API health HTTP ${res.statusCode}: $text');
      }
    } on Object catch (e) {
      throw StateError(
        '无法连接 Python demo API ($baseUrl)。\n'
        '请先启动: cd example_app && python3 server/app.py\n'
        '原因: $e',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final data = await _postJson('/api/login', {
      'email': email,
      'password': password,
    });
    final t = data['token']?.toString();
    if (t != null && t.isNotEmpty) {
      _token = t;
    }
    return data;
  }

  Future<Map<String, dynamic>?> fetchMe() async {
    final data = await _getJson('/api/me', bearer: _token);
    if (data['ok'] != true) return null;
    final user = data['user'];
    if (user is Map) return Map<String, dynamic>.from(user);
    return null;
  }

  Future<Map<String, dynamic>> updateDisplayName(String displayName) async {
    final data = await _postJson(
      '/api/profile',
      {'displayName': displayName},
      bearer: _token,
    );
    return data;
  }

  Future<Map<String, dynamic>> uploadAvatar({
    required Uint8List bytes,
    required String contentType,
  }) async {
    final data = await _postJson(
      '/api/profile/avatar',
      {
        'contentType': contentType,
        'dataBase64': base64Encode(bytes),
      },
      bearer: _token,
    );
    return data;
  }

  Future<List<Map<String, dynamic>>> fetchHomeList() async {
    final data = await _getJson('/api/home/list', bearer: _token);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$baseUrl$path'));
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      if (bearer != null && bearer.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      req.add(bytes);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (text.isEmpty) return {'ok': res.statusCode < 400};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    String? bearer,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$baseUrl$path'));
      if (bearer != null && bearer.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }
}
