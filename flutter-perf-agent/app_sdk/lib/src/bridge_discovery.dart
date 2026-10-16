import 'dart:convert';
import 'dart:io';

/// Well-known file so MCP can find the bridge when the preferred port is busy.
class BridgeDiscovery {
  BridgeDiscovery._();

  static const bridgeName = 'flutter-perf-agent';

  static File file() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return File('$home/.flutter_perf_agent/bridge.json');
  }

  static Future<void> write({
    required String host,
    required int port,
    String? vmServiceUri,
  }) async {
    final payload = <String, dynamic>{
      'bridge': bridgeName,
      'host': host,
      'port': port,
      'pid': pid,
      'updatedAt': DateTime.now().toIso8601String(),
      if (vmServiceUri != null) 'vmServiceUri': vmServiceUri,
    };
    final body = jsonEncode(payload);
    // Prefer real home; also mirror under /tmp so MCP works if the app is sandboxed.
    final targets = <File>[
      file(),
      File('${Directory.systemTemp.path}/flutter_perf_agent_bridge.json'),
      File('/tmp/flutter_perf_agent_bridge.json'),
    ];
    Object? lastError;
    var wrote = false;
    for (final f in targets) {
      try {
        await f.parent.create(recursive: true);
        await f.writeAsString(body);
        wrote = true;
      } catch (e) {
        lastError = e;
      }
    }
    if (!wrote && lastError != null) {
      throw StateError('BridgeDiscovery.write failed: $lastError');
    }
  }

  static Future<({String host, int port})?> read() async {
    final f = file();
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString());
      if (json is! Map) return null;
      final map = Map<String, dynamic>.from(json);
      if (map['bridge'] != null && map['bridge'] != bridgeName) return null;
      final host = map['host'] as String? ?? '127.0.0.1';
      final port = (map['port'] as num?)?.toInt();
      if (port == null || port <= 0) return null;
      return (host: host, port: port);
    } catch (_) {
      return null;
    }
  }
}
