import 'dart:io';

import 'flutter_skill_vm_client.dart';

/// Resolve a **host-reachable** VM Service WebSocket URI.
///
/// Aligns with flutter_skill's practical model: connect to an address that
/// already works on the MCP machine (simulator loopback, or USB-forwarded
/// port from `flutter run` / IDE), instead of blindly using the App-reported
/// `127.0.0.1:<devicePort>` which is unreachable from macOS for physical phones.
class VmUriResolver {
  VmUriResolver._();

  /// [bridgeRaw] from Bridge `/health` (`http://127.0.0.1:devicePort/token=/`).
  static Future<String?> resolve(
    String? bridgeRaw, {
    bool debugLog = false,
  }) async {
    void log(String m) {
      if (debugLog) stderr.writeln('[vm_uri_resolver] $m');
    }

    final token = _tokenOf(bridgeRaw);
    final devicePort = _portOf(bridgeRaw);

    // 1) Bridge URI as-is (simulator / already host-local).
    if (bridgeRaw != null && bridgeRaw.trim().isNotEmpty) {
      final asIs = FlutterSkillVmClient.normalizeWsUri(bridgeRaw);
      if (await _httpReachable(asIs)) {
        log('bridge URI reachable as-is: $asIs');
        return asIs;
      }
      log('bridge URI not reachable from host: $asIs');
    }

    // 2) Rewrite via running iproxy HOST:DEVICE (flutter run / F5).
    if (devicePort != null && token != null) {
      final hostPort = await _iproxyHostPortFor(devicePort);
      if (hostPort != null) {
        final rewritten = _wsWithPort(token: token, port: hostPort);
        if (await _httpReachable(rewritten)) {
          log('iproxy rewrite $devicePort → $hostPort: $rewritten');
          return rewritten;
        }
        log('iproxy map $devicePort→$hostPort not reachable');
      }
    }

    // 3) flutter_skill-style: scrape Flutter tooling process for host URI.
    final fromPs = await _discoverFromFlutterProcesses(preferToken: token);
    if (fromPs != null && await _httpReachable(fromPs)) {
      log('process discovery: $fromPs');
      return fromPs;
    }

    // 4) Any iproxy listener + matching token path.
    if (token != null) {
      for (final hostPort in await _allIproxyHostPorts()) {
        final candidate = _wsWithPort(token: token, port: hostPort);
        if (await _httpReachable(candidate)) {
          log('iproxy scan hit :$hostPort');
          return candidate;
        }
      }
    }

    // Last resort: return normalized bridge URI (caller may still fail connect).
    if (bridgeRaw != null && bridgeRaw.trim().isNotEmpty) {
      final fallback = FlutterSkillVmClient.normalizeWsUri(bridgeRaw);
      log('fallback to bridge URI (may fail on device): $fallback');
      return fallback;
    }
    return null;
  }

  static String? _tokenOf(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final path = Uri.parse(raw.trim()).path;
      final segs =
          path.split('/').where((s) => s.isNotEmpty && s != 'ws').toList();
      if (segs.isEmpty) return null;
      return segs.first;
    } catch (_) {
      return null;
    }
  }

  static int? _portOf(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return Uri.parse(raw.trim()).port;
    } catch (_) {
      return null;
    }
  }

  static String _wsWithPort({required String token, required int port}) {
    return FlutterSkillVmClient.normalizeWsUri(
      'http://127.0.0.1:$port/$token/',
    );
  }

  /// `iproxy 52418:55647` → host 52418 forwards to device 55647.
  static Future<int?> _iproxyHostPortFor(int devicePort) async {
    final map = await _iproxyMaps();
    return map[devicePort];
  }

  static Future<List<int>> _allIproxyHostPorts() async {
    final map = await _iproxyMaps();
    return map.values.toList();
  }

  static Future<Map<int, int>> _iproxyMaps() async {
    // devicePort → hostPort
    final out = <int, int>{};
    try {
      final r = await Process.run('ps', ['aux']);
      final lines = (r.stdout as String).split('\n');
      final re = RegExp(r'iproxy\s+(\d+):(\d+)');
      for (final line in lines) {
        final m = re.firstMatch(line);
        if (m == null) continue;
        final host = int.tryParse(m.group(1)!);
        final device = int.tryParse(m.group(2)!);
        if (host != null && device != null) out[device] = host;
      }
    } catch (_) {}
    return out;
  }

  /// Same idea as flutter_skill ProcessBasedDiscovery: read tooling cmdline.
  static Future<String?> _discoverFromFlutterProcesses({
    String? preferToken,
  }) async {
    try {
      final r = await Process.run('ps', ['aux']);
      final lines = (r.stdout as String).split('\n');
      String? fallback;
      for (final line in lines) {
        // development-service --vm-service-uri=http://127.0.0.1:PORT/TOKEN=/
        final m = RegExp(
          r'--vm-service-uri=(https?://[^\s]+)',
        ).firstMatch(line);
        if (m == null) continue;
        final raw = m.group(1)!;
        final ws = FlutterSkillVmClient.normalizeWsUri(raw);
        final tok = _tokenOf(raw);
        if (preferToken != null && tok == preferToken) return ws;
        fallback ??= ws;
      }
      // Also match console-style URIs embedded in flutter_tools command lines.
      for (final line in lines) {
        final m = RegExp(
          r'(ws://127\.0\.0\.1:\d+/[^/\s]+/ws)',
        ).firstMatch(line);
        if (m == null) continue;
        final ws = m.group(1)!;
        if (preferToken != null && ws.contains(preferToken)) return ws;
        fallback ??= ws;
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  /// Observatory answers HTTP even without DDS (often 200/403/400).
  static Future<bool> _httpReachable(String wsUri) async {
    try {
      var http = wsUri;
      if (http.startsWith('ws://')) {
        http = http.replaceFirst('ws://', 'http://');
      } else if (http.startsWith('wss://')) {
        http = http.replaceFirst('wss://', 'https://');
      }
      if (http.endsWith('/ws')) {
        http = http.substring(0, http.length - 2);
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 600);
      try {
        final req = await client.getUrl(Uri.parse(http));
        final res =
            await req.close().timeout(const Duration(milliseconds: 800));
        await res.drain<void>();
        // Any HTTP response means something is listening with that path/port.
        return res.statusCode > 0;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return false;
    }
  }
}
