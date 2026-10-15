import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'perf_snapshot.dart';
import 'sleuth_facade.dart';
import 'ui_actions.dart';

/// Local HTTP bridge: session + full Sleuth exports for the PC-side MCP server.
///
/// UI actions (tap/scroll/input) are owned by **flutter_skill** (VM extensions).
/// Bridge `/tap` is a legacy fallback. Sleuth full dumps go through `/sleuth/*`.
class PerfBridgeServer {
  PerfBridgeServer({
    this.host = '127.0.0.1',
    this.port = 19288,
    this.waitStableMs = 500,
  });

  final String host;
  final int port;
  final int waitStableMs;

  HttpServer? _server;
  String? sessionId;
  String? testName;
  DateTime? sessionStartedAt;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    if (kIsWeb) {
      debugPrint('[PerfBridge] skipped on web');
      return;
    }

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
      ..get('/sleuth/route_health', _sleuthRouteHealth);

    final handler = const Pipeline()
        .addMiddleware(logRequests(logger: (msg, isError) {
          if (isError) debugPrint('[PerfBridge] $msg');
        }))
        .addMiddleware(_cors)
        .addHandler(router.call);

    _server = await shelf_io.serve(handler, host, port);
    debugPrint('[PerfBridge] listening on http://$host:$port');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
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

  Response _json(Object body, {int status = 200}) => Response(
        status,
        body: jsonEncode(body),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<Response> _health(Request request) async {
    final vmUri = await _vmServiceUri();
    return _json({
      'ok': true,
      'bridge': 'flutter-perf-agent',
      'version': '0.4.1',
      'sessionId': sessionId,
      'testName': testName,
      'vmServiceUri': vmUri,
      'uiDriver': 'flutter_skill',
      'sleuth': SleuthFacade.diagnose(),
      'mode': kReleaseMode
          ? 'release'
          : (kProfileMode ? 'profile' : 'debug'),
    });
  }

  Future<Response> _sessionStart(Request request) async {
    final body = await _readJson(request);
    sessionId = body['sessionId'] as String? ??
        'sess_${DateTime.now().millisecondsSinceEpoch}';
    testName = body['testName'] as String? ?? 'unnamed';
    sessionStartedAt = DateTime.now();
    final wait = body['waitStableMs'] as int? ?? waitStableMs;

    await _waitStable(wait);

    // RSS-only baseline — full Sleuth export can stall the UI isolate on cold start.
    return _json({
      'ok': true,
      'sessionId': sessionId,
      'testName': testName,
      'startedAt': sessionStartedAt!.toIso8601String(),
      'vmServiceUri': await _vmServiceUri(),
      'baseline': PerfSnapshot.capture(sleuth: false).toJson(),
    });
  }

  Future<Response> _sessionStop(Request request) async {
    final ended = DateTime.now();
    final summary = {
      'ok': true,
      'sessionId': sessionId,
      'testName': testName,
      'startedAt': sessionStartedAt?.toIso8601String(),
      'endedAt': ended.toIso8601String(),
      'finalSnapshot': PerfSnapshot.capture(sleuth: false).toJson(),
    };
    sessionId = null;
    testName = null;
    sessionStartedAt = null;
    return _json(summary);
  }

  FutureOr<Response> _snapshot(Request request) {
    final includeRaw = request.url.queryParameters['raw'] == '1';
    return _json({
      'ok': true,
      'snapshot': PerfSnapshot.capture(includeRaw: includeRaw).toJson(),
    });
  }

  Future<Response> _wait(Request request) async {
    final body = await _readJson(request);
    final wait = body['waitStableMs'] as int? ?? waitStableMs;
    final frames = body['frames'] as int? ?? 2;
    await _waitStable(wait, frames: frames);
    return _json({'ok': true, 'waitedMs': wait, 'frames': frames});
  }

  FutureOr<Response> _ui(Request request) {
    return _json({
      'ok': true,
      'elements': UiActions.dumpInteractive(),
      'note': 'Prefer flutter_skill inspectInteractive via MCP when available',
    });
  }

  FutureOr<Response> _sleuthSnapshot(Request request) {
    final compact = request.url.queryParameters['compact'] == '1';
    return _json(SleuthFacade.snapshot(compact: compact));
  }

  FutureOr<Response> _sleuthSummary(Request request) {
    final topN =
        int.tryParse(request.url.queryParameters['topN'] ?? '') ?? 5;
    return _json(SleuthFacade.summary(topN: topN));
  }

  FutureOr<Response> _sleuthDiagnose(Request request) {
    return _json(SleuthFacade.diagnose());
  }

  FutureOr<Response> _sleuthIssues(Request request) {
    final limit =
        int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 50;
    return _json(SleuthFacade.issues(limit: limit));
  }

  FutureOr<Response> _sleuthRouteHealth(Request request) {
    final route = request.url.queryParameters['route'];
    return _json(SleuthFacade.routeHealth(routeName: route));
  }

  /// Legacy in-process tap. Prefer MCP → flutter_skill VM extension.
  Future<Response> _tapLegacy(Request request) async {
    final body = await _readJson(request);
    final target = (body['targetDesc'] as String?)?.trim() ?? '';
    if (target.isEmpty) {
      return _json({'ok': false, 'error': 'targetDesc is required'}, status: 400);
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

    return _json({
      'ok': action['ok'] == true,
      'legacy': true,
      'action': action,
      'diff': diff.toJson(),
      'sessionId': sessionId,
      'warning':
          'Bridge /tap is legacy. Primary path is flutter_skill via MCP.',
    });
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
      } catch (_) {
        // Idle / paused UI isolate — don't block the HTTP bridge forever.
      }
    }

    await framesOrTimeout();
    if (ms > 0) {
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
    await framesOrTimeout();
  }
}
