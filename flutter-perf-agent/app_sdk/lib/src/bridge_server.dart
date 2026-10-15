import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'perf_snapshot.dart';
import 'ui_actions.dart';

/// Local HTTP bridge so the PC-side MCP server can drive the app.
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
      ..post('/tap', _tap)
      ..get('/ui', _ui);

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

  FutureOr<Response> _health(Request request) {
    return _json({
      'ok': true,
      'bridge': 'flutter-perf-agent',
      'version': '0.1.0',
      'sessionId': sessionId,
      'testName': testName,
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

    return _json({
      'ok': true,
      'sessionId': sessionId,
      'testName': testName,
      'startedAt': sessionStartedAt!.toIso8601String(),
      'baseline': PerfSnapshot.capture().toJson(),
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
      'finalSnapshot': PerfSnapshot.capture().toJson(),
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

  FutureOr<Response> _ui(Request request) {
    return _json({
      'ok': true,
      'elements': UiActions.dumpInteractive(),
    });
  }

  Future<Response> _tap(Request request) async {
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
      'action': action,
      'diff': diff.toJson(),
      'sessionId': sessionId,
    });
  }

  Future<Map<String, dynamic>> _readJson(Request request) async {
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  Future<void> _waitStable(int ms) async {
    await SchedulerBinding.instance.endOfFrame;
    if (ms > 0) {
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
    await SchedulerBinding.instance.endOfFrame;
  }
}
