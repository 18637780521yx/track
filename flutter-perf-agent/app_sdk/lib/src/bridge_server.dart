import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'bridge_discovery.dart';
import 'network_capture.dart';
import 'perf_snapshot.dart';
import 'sleuth_facade.dart';
import 'ui_actions.dart';

/// Local HTTP bridge: session + full Sleuth exports for the PC-side MCP server.
///
/// All JSON bodies use `{ code, data, msg }`.
class PerfBridgeServer {
  PerfBridgeServer({
    this.host = '127.0.0.1',
    this.port = 19288,
    this.waitStableMs = 500,
    this.bindRetries = 10,
    this.bindRetryDelay = const Duration(milliseconds: 250),
    this.portFallbackCount = 10,
  });

  final String host;
  /// Preferred listen port (may fall back if occupied).
  final int port;
  final int waitStableMs;
  final int bindRetries;
  final Duration bindRetryDelay;
  final int portFallbackCount;

  HttpServer? _server;
  int? _boundPort;
  String? sessionId;
  String? testName;
  DateTime? sessionStartedAt;

  /// Survives Sleuth route-transition `clearRecords` so login/list APIs
  /// still appear in step reports after navigation.
  final Map<String, NetworkRequest> _networkArchive = {};
  Timer? _networkIngestTimer;

  bool get isRunning => _server != null;

  /// Actual bound port after [start]; equals [port] when no fallback was needed.
  int get boundPort => _boundPort ?? port;

  Future<void> start() async {
    if (_server != null) return;
    if (kIsWeb) {
      debugPrint('[PerfBridge] skipped on web');
      return;
    }

    final handler = _buildHandler();
    Object? lastError;

    // 1) Prefer the configured port — hot restart often races the old socket.
    for (var attempt = 1; attempt <= bindRetries; attempt++) {
      try {
        await _listen(handler, port);
        return;
      } catch (e) {
        lastError = e;
        if (!_isAddrInUse(e)) rethrow;
        // true = another PerfBridge; false = foreign listener; null = race/empty.
        final probe = await _probePort(port);
        if (probe == true) {
          debugPrint(
            '[PerfBridge] port $port already served by another PerfBridge; '
            'falling back',
          );
          break;
        }
        if (probe == false) {
          debugPrint(
            '[PerfBridge] port $port held by a non-bridge process; falling back',
          );
          break;
        }
        debugPrint(
          '[PerfBridge] port $port in use '
          '(attempt $attempt/$bindRetries), retrying…',
        );
        await Future<void>.delayed(bindRetryDelay);
      }
    }

    // 2) Another live process still owns the preferred port — fall back.
    final maxPort = port + portFallbackCount;
    for (var candidate = port + 1; candidate <= maxPort; candidate++) {
      try {
        await _listen(handler, candidate);
        debugPrint(
          '[PerfBridge] preferred port $port busy; '
          'listening on fallback http://$host:$candidate',
        );
        return;
      } catch (e) {
        lastError = e;
        if (!_isAddrInUse(e)) rethrow;
        debugPrint('[PerfBridge] port $candidate also in use, trying next…');
      }
    }

    throw StateError(
      'PerfBridge failed to bind $host:$port–$maxPort '
      '(last error: $lastError)',
    );
  }

  Handler _buildHandler() {
    final router = Router()
      ..get('/health', _health)
      ..post('/session/start', _sessionStart)
      ..post('/session/stop', _sessionStop)
      ..get('/snapshot', _snapshot)
      ..post('/wait', _wait)
      ..post('/tap', _tapLegacy)
      ..get('/ui', _ui)
      ..get('/sleuth/snapshot', _sleuthSnapshot)
      ..get('/sleuth/summary', _sleuthSummary)
      ..get('/sleuth/diagnose', _sleuthDiagnose)
      ..get('/sleuth/issues', _sleuthIssues)
      ..get('/sleuth/route_health', _sleuthRouteHealth)
      ..get('/sleuth/startup', _sleuthStartup)
      ..get('/network', _network)
      ..get('/app/route', _appRoute);

    return const Pipeline()
        .addMiddleware(logRequests(logger: (msg, isError) {
          if (isError) debugPrint('[PerfBridge] $msg');
        }))
        .addMiddleware(_cors)
        .addHandler(router.call);
  }

  Future<void> _listen(Handler handler, int listenPort) async {
    final server = await shelf_io.serve(handler, host, listenPort);
    _server = server;
    _boundPort = server.port;
    final vmUri = await _vmServiceUri();
    try {
      await BridgeDiscovery.write(
        host: host,
        port: boundPort,
        vmServiceUri: vmUri,
      );
    } catch (e) {
      debugPrint('[PerfBridge] discovery write skipped: $e');
    }
    debugPrint('[PerfBridge] listening on http://$host:$boundPort');
  }

  static bool _isAddrInUse(Object e) {
    if (e is! SocketException) return false;
    final code = e.osError?.errorCode;
    // macOS 48, Linux 98, Windows 10048
    if (code == 48 || code == 98 || code == 10048) return true;
    final msg = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    return msg.contains('already in use') ||
        msg.contains('address in use') ||
        msg.contains('eaddrinuse');
  }

  /// `true` = our bridge, `false` = something else listening, `null` = unreachable.
  Future<bool?> _probePort(int probePort) async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 400);
      final req =
          await client.getUrl(Uri.parse('http://$host:$probePort/health'));
      final res = await req.close().timeout(const Duration(milliseconds: 600));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return false;
      final decoded = jsonDecode(body);
      if (decoded is! Map) return false;
      final data = decoded['data'];
      if (data is Map && data['bridge'] == BridgeDiscovery.bridgeName) {
        return true;
      }
      return false;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      // TCP accepted but not our JSON health → foreign listener.
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _boundPort = null;
  }

  Middleware get _cors => (inner) {
        return (request) async {
          if (request.method == 'OPTIONS') {
            return Response.ok('', headers: _corsHeaders);
          }
          final res = await inner(request);
          return res.change(headers: _corsHeaders);
        };
      };

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };

  Response _envelope(ApiResponse<dynamic> response, {int? httpStatus}) {
    final status = httpStatus ??
        (response.isOk
            ? 200
            : (response.code == ApiCodes.badRequest ? 400 : 200));
    return Response(
      status,
      body: jsonEncode(response.toJson()),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<Response> _health(Request request) async {
    final vmUri = await _vmServiceUri();
    final sleuth = SleuthFacade.diagnose();
    return _envelope(
      ApiResponse.ok(
        HealthData(
          bridge: 'flutter-perf-agent',
          version: '0.6.0',
          sessionId: sessionId,
          testName: testName,
          vmServiceUri: vmUri,
          uiDriver: 'flutter_skill',
          sleuth: sleuth.data,
          mode: kReleaseMode
              ? 'release'
              : (kProfileMode ? 'profile' : 'debug'),
        ),
      ),
    );
  }

  Future<Response> _sessionStart(Request request) async {
    final body = await _readJson(request);
    sessionId = body['sessionId'] as String? ??
        'sess_${DateTime.now().millisecondsSinceEpoch}';
    testName = body['testName'] as String? ?? 'unnamed';
    sessionStartedAt = DateTime.now();
    final wait = body['waitStableMs'] as int? ?? waitStableMs;

    _networkArchive.clear();
    PerfNetworkStore.instance.clear();
    _startNetworkIngest();
    await _waitStable(wait);

    return _envelope(
      ApiResponse.ok(
        SessionStartData(
          sessionId: sessionId!,
          testName: testName!,
          startedAt: sessionStartedAt!.toIso8601String(),
          vmServiceUri: await _vmServiceUri(),
          baseline: PerfSnapshot.capture(sleuth: false).toPayload(),
        ),
      ),
    );
  }

  Future<Response> _sessionStop(Request request) async {
    final ended = DateTime.now();
    _ingestNetwork();
    _stopNetworkIngest();
    final data = SessionStopData(
      sessionId: sessionId,
      testName: testName,
      startedAt: sessionStartedAt?.toIso8601String(),
      endedAt: ended.toIso8601String(),
      finalSnapshot: PerfSnapshot.capture(sleuth: false).toPayload(),
    );
    sessionId = null;
    testName = null;
    sessionStartedAt = null;
    return _envelope(ApiResponse.ok(data));
  }

  void _startNetworkIngest() {
    _networkIngestTimer?.cancel();
    _ingestNetwork();
    _networkIngestTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _ingestNetwork(),
    );
  }

  void _stopNetworkIngest() {
    _networkIngestTimer?.cancel();
    _networkIngestTimer = null;
  }

  void _ingestNetwork() {
    // Prefer full HttpCapture (headers + bodies); keep Sleuth as fallback.
    for (final r in PerfNetworkStore.instance.records) {
      final key = _networkDedupeKey(r);
      final existing = _networkArchive[key];
      if (existing == null || (!existing.hasPayload && r.hasPayload)) {
        _networkArchive[key] = r;
      }
    }
    final live = SleuthFacade.networkRequests(limit: 200);
    if (!live.isOk || live.data == null) return;
    for (final r in live.data!.requests) {
      final key = _networkDedupeKey(r);
      if (_networkArchive.containsKey(key)) continue;
      if (_hasNearbyFull(r)) continue;
      _networkArchive.putIfAbsent(key, () => r);
    }
  }

  String _networkDedupeKey(NetworkRequest r) {
    // Bucket startedAt to 1s to collapse double-emit / sleuth+full twins.
    final at = DateTime.tryParse(r.startedAt);
    final bucket = at == null
        ? r.startedAt
        : at.toUtc().toIso8601String().substring(0, 19);
    return '$bucket|${r.method.toUpperCase()}|${r.url}|${r.statusCode}';
  }

  bool _hasNearbyFull(NetworkRequest thin) {
    final thinAt = DateTime.tryParse(thin.startedAt);
    if (thinAt == null) return false;
    for (final full in _networkArchive.values) {
      if (!full.hasPayload) continue;
      if (full.method.toUpperCase() != thin.method.toUpperCase()) continue;
      if (full.url != thin.url) continue;
      if (full.statusCode != thin.statusCode) continue;
      final fullAt = DateTime.tryParse(full.startedAt);
      if (fullAt == null) continue;
      if (fullAt.difference(thinAt).inMilliseconds.abs() <= 3000) return true;
    }
    return false;
  }

  FutureOr<Response> _snapshot(Request request) {
    final includeRaw = request.url.queryParameters['raw'] == '1';
    return _envelope(
      ApiResponse.ok(
        SnapshotData(
          snapshot: PerfSnapshot.capture(includeRaw: includeRaw).toPayload(),
        ),
      ),
    );
  }

  Future<Response> _wait(Request request) async {
    final body = await _readJson(request);
    final wait = body['waitStableMs'] as int? ?? waitStableMs;
    final frames = body['frames'] as int? ?? 2;
    await _waitStable(wait, frames: frames);
    return _envelope(
      ApiResponse.ok(WaitData(waitedMs: wait, frames: frames)),
    );
  }

  FutureOr<Response> _ui(Request request) {
    return _envelope(
      ApiResponse.ok(
        UiDumpData(
          elements: UiActions.dumpInteractive(),
          note: 'Prefer flutter_skill inspectInteractive via MCP when available',
        ),
      ),
    );
  }

  FutureOr<Response> _sleuthSnapshot(Request request) {
    final compact = request.url.queryParameters['compact'] == '1';
    return _envelope(SleuthFacade.snapshot(compact: compact));
  }

  FutureOr<Response> _sleuthSummary(Request request) {
    final topN =
        int.tryParse(request.url.queryParameters['topN'] ?? '') ?? 5;
    return _envelope(SleuthFacade.summary(topN: topN));
  }

  FutureOr<Response> _sleuthDiagnose(Request request) {
    return _envelope(SleuthFacade.diagnose());
  }

  FutureOr<Response> _sleuthIssues(Request request) {
    final limit =
        int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 50;
    return _envelope(SleuthFacade.issues(limit: limit));
  }

  FutureOr<Response> _sleuthRouteHealth(Request request) {
    final route = request.url.queryParameters['route'];
    return _envelope(SleuthFacade.routeHealth(routeName: route));
  }

  FutureOr<Response> _sleuthStartup(Request request) {
    return _envelope(SleuthFacade.startup());
  }

  FutureOr<Response> _network(Request request) {
    final since = request.url.queryParameters['since'];
    final limit =
        int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100;
    _ingestNetwork();
    DateTime? sinceAt;
    if (since != null && since.isNotEmpty) {
      sinceAt = DateTime.tryParse(since);
    }
    final all = _networkArchive.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final filtered = <NetworkRequest>[];
    for (final r in all) {
      if (sinceAt != null) {
        final at = DateTime.tryParse(r.startedAt);
        if (at != null && at.isBefore(sinceAt)) continue;
      }
      filtered.add(r);
    }
    final clipped = filtered.length > limit
        ? filtered.sublist(filtered.length - limit)
        : filtered;
    return _envelope(
      ApiResponse.ok(
        NetworkRequestsData(requests: clipped, since: since),
      ),
    );
  }

  FutureOr<Response> _appRoute(Request request) {
    final route = PerfNetworkCapture.currentRoute() ?? '';
    return _envelope(ApiResponse.ok(AppRouteData(route: route)));
  }

  Future<Response> _tapLegacy(Request request) async {
    final body = await _readJson(request);
    final target = (body['targetDesc'] as String?)?.trim() ?? '';
    if (target.isEmpty) {
      return _envelope(
        ApiResponse.fail(ApiCodes.badRequest, 'targetDesc is required'),
        httpStatus: 400,
      );
    }
    final wait = body['waitStableMs'] as int? ?? waitStableMs;

    final before = PerfSnapshot.capture();
    final t0 = DateTime.now();
    final action = await UiActions.tapByDescription(target);
    await _waitStable(wait);
    final after = PerfSnapshot.capture();
    final diff = PerfDiff(
      before: before,
      after: after,
      durationMs: DateTime.now().difference(t0).inMilliseconds,
    );

    final data = TapLegacyData(
      legacy: true,
      action: action,
      diff: diff.toData(),
      sessionId: sessionId,
      warning:
          'Bridge /tap is legacy. Primary path is flutter_skill via MCP.',
    );

    if (!action.success) {
      return _envelope(
        ApiResponse.fail(ApiCodes.actionFailed, action.error ?? 'tap failed',
            data: data),
      );
    }
    return _envelope(ApiResponse.ok(data));
  }

  Future<String?> _vmServiceUri() async {
    try {
      final info = await developer.Service.getInfo();
      return info.serverUri?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _readJson(Request request) async {
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  Future<void> _waitStable(int ms, {int frames = 2}) async {
    final frameCount = frames < 1 ? 1 : frames;
    Future<void> framesOrTimeout() async {
      try {
        for (var i = 0; i < frameCount; i++) {
          await SchedulerBinding.instance.endOfFrame
              .timeout(const Duration(seconds: 2));
        }
      } catch (_) {}
    }

    await framesOrTimeout();
    if (ms > 0) {
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
    await framesOrTimeout();
  }
}
