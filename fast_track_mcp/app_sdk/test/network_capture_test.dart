import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    PerfNetworkStore.instance.clear();
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
}
