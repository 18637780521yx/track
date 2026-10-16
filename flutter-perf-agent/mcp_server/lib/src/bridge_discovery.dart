import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Locate a live PerfBridge when the configured port is down or remapped.
class BridgeDiscovery {
  BridgeDiscovery._();

  static const bridgeName = 'flutter-perf-agent';

  static File file() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return File('$home/.flutter_perf_agent/bridge.json');
  }

  /// Returns a reachable base URL (`http://host:port`) or null.
  static Future<String?> resolve({
    required String preferredHost,
    required int preferredPort,
    http.Client? client,
    int portScanExtra = 10,
  }) async {
    final httpClient = client ?? http.Client();
    final ownedClient = client == null;
    try {
      final preferred = 'http://$preferredHost:$preferredPort';
      if (await _isOurBridge(httpClient, preferred)) return preferred;

      final fromFile = await _fromDiscoveryFile();
      if (fromFile != null && await _isOurBridge(httpClient, fromFile)) {
        return fromFile;
      }

      for (var port = preferredPort;
          port <= preferredPort + portScanExtra;
          port++) {
        final url = 'http://$preferredHost:$port';
        if (url == preferred) continue;
        if (await _isOurBridge(httpClient, url)) return url;
      }
      return null;
    } finally {
      if (ownedClient) httpClient.close();
    }
  }

  static Future<String?> _fromDiscoveryFile() async {
    final candidates = <File>[
      file(),
      File('${Directory.systemTemp.path}/flutter_perf_agent_bridge.json'),
      File('/tmp/flutter_perf_agent_bridge.json'),
    ];
    // macOS App Sandbox containers (example_app / host apps).
    final home = Platform.environment['HOME'];
    if (home != null) {
      final containers = Directory('$home/Library/Containers');
      if (await containers.exists()) {
        await for (final entity in containers.list(followLinks: false)) {
          if (entity is! Directory) continue;
          candidates.add(
            File('${entity.path}/Data/.flutter_perf_agent/bridge.json'),
          );
        }
      }
    }

    ({String host, int port, DateTime? updatedAt})? best;
    for (final f in candidates) {
      final parsed = await _parseDiscoveryFile(f);
      if (parsed == null) continue;
      if (best == null ||
          (parsed.updatedAt != null &&
              (best.updatedAt == null ||
                  parsed.updatedAt!.isAfter(best.updatedAt!)))) {
        best = parsed;
      }
    }
    if (best == null) return null;
    return 'http://${best.host}:${best.port}';
  }

  static Future<({String host, int port, DateTime? updatedAt})?>
      _parseDiscoveryFile(File f) async {
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString());
      if (json is! Map) return null;
      final map = Map<String, dynamic>.from(json);
      if (map['bridge'] != null && map['bridge'] != bridgeName) return null;
      final host = map['host'] as String? ?? '127.0.0.1';
      final port = (map['port'] as num?)?.toInt();
      if (port == null || port <= 0) return null;
      DateTime? updatedAt;
      final raw = map['updatedAt'] as String?;
      if (raw != null) updatedAt = DateTime.tryParse(raw);
      return (host: host, port: port, updatedAt: updatedAt);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _isOurBridge(http.Client client, String baseUrl) async {
    try {
      final res = await client
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(milliseconds: 800));
      if (res.statusCode != 200) return false;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return false;
      final data = decoded['data'];
      if (data is Map && data['bridge'] == bridgeName) return true;
      // Envelope without nested data, or loose match on top-level.
      return decoded['bridge'] == bridgeName ||
          (decoded['code'] == 0 && data is Map);
    } catch (_) {
      return false;
    }
  }
}
