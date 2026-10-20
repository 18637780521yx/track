import 'dart:convert';

import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:http/http.dart' as http;

import 'bridge_discovery.dart';
import 'config.dart';

class BridgeClient {
  BridgeClient(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  final PerfAgentConfig config;
  final http.Client _client;

  String? _resolvedBaseUrl;

  /// Last successfully resolved bridge base URL (after [ensureResolved]).
  String get bridgeBaseUrl => _resolvedBaseUrl ?? config.bridgeBaseUrl;

  Uri _u(String path) => Uri.parse('$bridgeBaseUrl$path');

  /// Ping configured port, then discovery file / nearby ports.
  Future<String?> ensureResolved({bool force = false}) async {
    if (!force && _resolvedBaseUrl != null) return _resolvedBaseUrl;
    final found = await BridgeDiscovery.resolve(
      preferredHost: config.bridgeHost,
      preferredPort: config.bridgePort,
      client: _client,
    );
    _resolvedBaseUrl = found;
    return found;
  }

  Future<ApiResponse<HealthData>> health() => _get(
        '/health',
        (raw) => HealthData.fromJson(_asMap(raw)),
      );

  Future<ApiResponse<SessionStartData>> startSession({
    required String testName,
    String? sessionId,
    int? waitStableMs,
    String? reportsDir,
    bool manualRecording = true,
  }) {
    return _post(
      '/session/start',
      {
        'testName': testName,
        if (sessionId != null) 'sessionId': sessionId,
        'waitStableMs': waitStableMs ?? config.waitStableMs,
        if (reportsDir != null) 'reportsDir': reportsDir,
        'manualRecording': manualRecording,
      },
      (raw) => SessionStartData.fromJson(_asMap(raw)),
    );
  }

  Future<ApiResponse<SessionStopData>> stopSession({
    bool writeReport = true,
  }) =>
      _post(
        '/session/stop',
        {'writeReport': writeReport},
        (raw) => SessionStopData.fromJson(_asMap(raw)),
      );

  /// Append a step into App SDK unified journal (source defaults to mcp).
  Future<ApiResponse<Map<String, dynamic>>> appendStep({
    required Map<String, dynamic> step,
    String? sessionId,
    String? testName,
  }) {
    return _post(
      '/session/step',
      {
        'step': step,
        if (sessionId != null) 'sessionId': sessionId,
        if (testName != null) 'testName': testName,
      },
      (raw) => _asMap(raw),
    );
  }

  /// Refresh App SDK live report (same HTML as manual).
  Future<ApiResponse<Map<String, dynamic>>> writeLiveReport() => _post(
        '/session/live',
        const {},
        (raw) => _asMap(raw),
      );

  /// Suppress manual gesture recording while MCP drives UI.
  Future<ApiResponse<Map<String, dynamic>>> mcpGuard({required bool active}) {
    return _post(
      '/session/mcp_guard',
      {'active': active},
      (raw) => _asMap(raw),
    );
  }

  Future<ApiResponse<Map<String, dynamic>>> journal() => _get(
        '/session/journal',
        (raw) => _asMap(raw),
      );

  Future<ApiResponse<SnapshotData>> snapshot({bool raw = false}) => _get(
        '/snapshot${raw ? '?raw=1' : ''}',
        (d) => SnapshotData.fromJson(_asMap(d)),
      );

  Future<ApiResponse<WaitData>> waitStable({int? waitStableMs}) {
    return _post(
      '/wait',
      {'waitStableMs': waitStableMs ?? config.waitStableMs},
      (raw) => WaitData.fromJson(_asMap(raw)),
    );
  }

  Future<ApiResponse<UiDumpData>> ui() => _get(
        '/ui',
        (raw) => UiDumpData.fromJson(_asMap(raw)),
      );

  Future<ApiResponse<SleuthSnapshotData>> sleuthSnapshot({
    bool compact = false,
  }) =>
      _get(
        '/sleuth/snapshot${compact ? '?compact=1' : ''}',
        (raw) => SleuthSnapshotData.fromJson(_asMap(raw)),
      );

  Future<ApiResponse<SleuthSummaryData>> sleuthSummary({int topN = 5}) => _get(
        '/sleuth/summary?topN=$topN',
        (raw) => SleuthSummaryData.fromJson(_asMap(raw)),
      );

  Future<ApiResponse<SleuthDiagnoseData>> sleuthDiagnose() => _get(
        '/sleuth/diagnose',
        (raw) => SleuthDiagnoseData.fromJson(_asMap(raw)),
      );

  Future<ApiResponse<SleuthIssuesData>> sleuthIssues({int limit = 50}) => _get(
        '/sleuth/issues?limit=$limit',
        (raw) => SleuthIssuesData.fromJson(_asMap(raw)),
      );

  Future<ApiResponse<SleuthRouteHealthData>> sleuthRouteHealth({
    String? routeName,
  }) {
    final q = (routeName == null || routeName.isEmpty)
        ? ''
        : '?route=${Uri.encodeQueryComponent(routeName)}';
    return _get(
      '/sleuth/route_health$q',
      (raw) => SleuthRouteHealthData.fromJson(_asMap(raw)),
    );
  }

  /// Current app route (`/login`, `/home#mine`, …) from PerfBridge.
  Future<ApiResponse<AppRouteData>> appRoute() => _get(
        '/app/route',
        (raw) => AppRouteData.fromJson(_asMap(raw)),
      );

  /// Post-pop WeakRef leak probe on the app (no forced GC).
  Future<ApiResponse<Map<String, dynamic>>> transitionLeakProbe({
    required String route,
    int? settleMs,
  }) {
    return _post(
      '/transition/leak_probe',
      {
        'route': route,
        if (settleMs != null) 'settleMs': settleMs,
      },
      (raw) => _asMap(raw),
    );
  }

  /// Sleuth cold-start metrics (TTFF / TTI). Empty [StartupMetricsData.metrics]
  /// until first frame after [Sleuth.init].
  Future<ApiResponse<StartupMetricsData>> sleuthStartup() => _get(
        '/sleuth/startup',
        (raw) => StartupMetricsData.fromJson(_asMap(raw)),
      );

  /// HTTP requests observed by Sleuth since [sinceIso] (ISO-8601).
  Future<ApiResponse<NetworkRequestsData>> networkRequests({
    String? sinceIso,
    int limit = 100,
  }) {
    final parts = <String>[];
    if (sinceIso != null && sinceIso.isNotEmpty) {
      parts.add('since=${Uri.encodeQueryComponent(sinceIso)}');
    }
    parts.add('limit=$limit');
    return _get(
      '/network?${parts.join('&')}',
      (raw) => NetworkRequestsData.fromJson(_asMap(raw)),
    );
  }

  Future<ApiResponse<TapLegacyData>> tapLegacy({
    required String targetDesc,
    int? waitStableMs,
  }) {
    return _post(
      '/tap',
      {
        'targetDesc': targetDesc,
        'waitStableMs': waitStableMs ?? config.waitStableMs,
      },
      (raw) => TapLegacyData.fromJson(_asMap(raw)),
    );
  }

  Future<ApiResponse<T>> _get<T>(
    String path,
    T Function(Object? raw) decode,
  ) async {
    await ensureResolved();
    try {
      final res = await _client
          .get(_u(path))
          .timeout(const Duration(seconds: 10));
      return _decode(res, decode);
    } catch (e) {
      final retried = await _retryAfterRediscover(
        () => _client.get(_u(path)).timeout(const Duration(seconds: 10)),
        decode,
      );
      if (retried != null) return retried;
      return ApiResponse.fail(
        ApiCodes.unavailable,
        'bridge unreachable: $e',
        data: null,
      );
    }
  }

  Future<ApiResponse<T>> _post<T>(
    String path,
    Map<String, dynamic> body,
    T Function(Object? raw) decode,
  ) async {
    await ensureResolved();
    Future<http.Response> send() => _client
        .post(
          _u(path),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    try {
      return _decode(await send(), decode);
    } catch (e) {
      final retried = await _retryAfterRediscover(send, decode);
      if (retried != null) return retried;
      return ApiResponse.fail(
        ApiCodes.unavailable,
        'bridge unreachable: $e',
      );
    }
  }

  Future<ApiResponse<T>?> _retryAfterRediscover<T>(
    Future<http.Response> Function() send,
    T Function(Object? raw) decode,
  ) async {
    final found = await ensureResolved(force: true);
    if (found == null) return null;
    try {
      return _decode(await send(), decode);
    } catch (_) {
      return null;
    }
  }

  ApiResponse<T> _decode<T>(
    http.Response res,
    T Function(Object? raw) decode,
  ) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        return ApiResponse.fail(ApiCodes.internal, 'unexpected response');
      }
      return ApiResponse.fromJson(decoded, decodeData: decode);
    } catch (e) {
      return ApiResponse.fail(
        ApiCodes.internal,
        'invalid json (${res.statusCode}): $e',
      );
    }
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  void close() => _client.close();
}
