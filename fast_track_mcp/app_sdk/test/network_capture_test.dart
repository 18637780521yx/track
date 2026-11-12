import 'dart:convert';
import 'dart:io';

import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:fast_track_mcp/src/detect/detect_sink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('request.done does not close POST before body is sent', () async {
    final previous = HttpOverrides.current;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpClient? client;
    FastTrackMcpDetectSink.debugOnTrack = (_, __) async {};
    try {
      FastTrackMcpNetwork.install(captureBodyOnFailureOnly: false);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 422;
        request.response.headers.contentType = ContentType.json;
        request.response
            .write(jsonEncode({'received': body, 'error': 'invalid'}));
        await request.response.close();
      });
      client = HttpClient();
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:${server.port}/draft'));
      final done = request.done;
      await Future<void>.delayed(Duration.zero);
      request.write('draft-content');
      final response = await request.close();
      expect(await done, same(response));
      expect(response.statusCode, 422);
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      expect(body['received'], 'draft-content');
      expect(PerfNetworkStore.instance.records, hasLength(1));
      expect(PerfNetworkStore.instance.records.single.responseBody,
          contains('invalid'));
    } finally {
      client?.close(force: true);
      HttpOverrides.global = previous;
      await server.close(force: true);
    }
  });

  test('explicit global capture records HTTP failures and installs only once',
      () async {
    final previous = HttpOverrides.current;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpClient? client;
    FastTrackMcpDetectSink.debugOnTrack = (_, __) async {};
    FastTrackMcpNetwork.emitQualityAlerts = false;
    try {
      FastTrackMcpNetwork.install(captureBodyOnFailureOnly: true);
      final installed = HttpOverrides.current;
      expect(FastTrackMcpNetwork.isInstalled, true);
      FastTrackMcpNetwork.install(captureBodyOnFailureOnly: true);
      expect(HttpOverrides.current, same(installed));
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode =
            request.uri.path == '/success' ? 200 : 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"message":"failed"}');
        await request.response.close();
      });
      client = HttpClient();
      final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/business?name=demo'));
      request.headers.set('x-test', 'demo');
      request.write('{"id":123}');
      final response = await request.close();
      expect(await utf8.decoder.bind(response).join(), '{"message":"failed"}');
      final record = PerfNetworkStore.instance.records.single;
      expect(record.statusCode, 500);
      expect(record.url, contains('name=demo'));
      expect(record.requestHeaders?['x-test'], 'demo');
      expect(record.requestBody, contains('123'));
      expect(record.responseBody, contains('failed'));

      // ensureInitialized's debug capture uses this policy: successful bodies
      // remain visible too, independently of the business result.
      FastTrackMcpNetwork.install(captureBodyOnFailureOnly: false);
      final successRequest = await client
          .postUrl(Uri.parse('http://127.0.0.1:${server.port}/success'));
      successRequest.headers.contentType = ContentType.json;
      successRequest.write('{"id":456}');
      final successResponse = await successRequest.close();
      await successResponse.drain<void>();
      final successRecord = PerfNetworkStore.instance.records.last;
      expect(successRecord.statusCode, 200);
      expect(successRecord.requestBody, contains('456'));
      expect(successRecord.responseBody, contains('failed'));
    } finally {
      client?.close(force: true);
      HttpOverrides.global = previous;
      await server.close(force: true);
    }
  });
  tearDown(() {
    PerfNetworkStore.instance.clear();
    PerfNetworkStore.instance.capacity = PerfNetworkStore.defaultCapacity;
    FastTrackMcpDetectSink.debugOnTrack = null;
    FastTrackMcpDetectSink.debugOnFlush = null;
    FastTrackMcpNetwork.slowRequestMs = 1000;
    FastTrackMcpNetwork.largeResponseBytes = 1024 * 1024;
    FastTrackMcpNetwork.emitQualityAlerts = true;
  });

  test('store ring buffer + since filter', () {
    final store = PerfNetworkStore.instance;
    store.capacity = 3;
    for (var i = 0; i < 5; i++) {
      store.add(
        NetworkRequest(
          url: 'https://x/$i',
          method: 'GET',
          statusCode: 200,
          durationMs: 10,
          responseBytes: 1,
          startedAt: DateTime.utc(2026, 1, 1, 0, 0, i).toIso8601String(),
          source: 'full',
        ),
      );
    }
    expect(store.records, hasLength(3));
    expect(store.records.first.url, 'https://x/2');

    final since = store.since(DateTime.utc(2026, 1, 1, 0, 0, 3));
    expect(since.map((e) => e.url).toList(), ['https://x/3', 'https://x/4']);
  });

  test('listener fires on add', () {
    NetworkRequest? got;
    void listener(NetworkRequest r) => got = r;
    PerfNetworkStore.instance.addListener(listener);
    PerfNetworkStore.instance.add(
      const NetworkRequest(
        url: 'https://a',
        method: 'POST',
        statusCode: 201,
        durationMs: 5,
        responseBytes: 2,
        startedAt: '2026-01-01T00:00:00.000Z',
      ),
    );
    expect(got?.url, 'https://a');
    PerfNetworkStore.instance.removeListener(listener);
  });

  test('NetworkRequest flags serialize', () {
    const r = NetworkRequest(
      url: 'https://api/x',
      method: 'GET',
      statusCode: 500,
      durationMs: 2000,
      responseBytes: 2 * 1024 * 1024,
      startedAt: '2026-01-01T00:00:00.000Z',
      path: '/x',
      flags: ['slow', 'large', 'http_error'],
    );
    final j = r.toJson();
    expect(j['flags'], ['slow', 'large', 'http_error']);
    expect(j['path'], '/x');
    final back = NetworkRequest.fromJson(j);
    expect(back.isSlow, isTrue);
    expect(back.isLarge, isTrue);
    expect(back.isHttpError, isTrue);
  });

  test('manual HTTP 200 business failure reaches telemetry without flushing',
      () async {
    final events = <String, Map<String, dynamic>>{};
    var flushes = 0;
    FastTrackMcpDetectSink.debugOnTrack = (name, props) async {
      events[name] = props;
    };
    FastTrackMcpDetectSink.debugOnFlush = () async {
      flushes++;
    };
    const request = NetworkRequest(
      url: 'https://api.example.com/order?id=123',
      method: 'POST',
      statusCode: 200,
      durationMs: 120,
      responseBytes: 42,
      startedAt: '2026-01-01T00:00:00.000Z',
      source: 'manual',
      requestHeaders: {'authorization': 'Bearer value'},
      requestBody: '{"id":123}',
      responseBody: '{"code":"OUT_OF_STOCK"}',
      businessSuccess: false,
      businessCode: 'OUT_OF_STOCK',
      businessMessage: 'No stock',
    );
    FastTrackMcpNetwork.record(request);
    await Future<void>.delayed(Duration.zero);
    expect(PerfNetworkStore.instance.records.single, same(request));
    final uploaded = NetworkRequest.fromJson(events['app_network']!);
    expect(uploaded.isBusinessError, true);
    expect(uploaded.statusCode, 200);
    expect(uploaded.businessCode, 'OUT_OF_STOCK');
    expect(uploaded.businessMessage, 'No stock');
    expect(uploaded.requestHeaders, request.requestHeaders);
    expect(uploaded.requestBody, request.requestBody);
    expect(uploaded.responseBody, request.responseBody);
    expect(events.keys, contains('perf_business_error'));
    expect(flushes, 0);
  });

  test(
      'business success and legacy unknown outcomes do not produce failure alerts',
      () async {
    final events = <String>[];
    FastTrackMcpDetectSink.debugOnTrack = (name, _) async {
      events.add(name);
    };
    for (final success in <bool?>[true, null]) {
      final request = NetworkRequest(
        url: 'https://api.example.com/order',
        method: 'GET',
        statusCode: 200,
        durationMs: 10,
        responseBytes: 0,
        startedAt: '2026-01-01T00:00:00.000Z',
        businessSuccess: success,
      );
      final restored = NetworkRequest.fromJson(request.toJson());
      expect(restored.businessSuccess, success);
      expect(restored.isBusinessError, false);
      FastTrackMcpNetwork.record(request);
    }
    await Future<void>.delayed(Duration.zero);
    expect(events, ['app_network', 'app_network']);
  });
}
