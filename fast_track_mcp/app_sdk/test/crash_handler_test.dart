import 'dart:async';

import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('fast_track_mcp/anr');
  const events = MethodChannel('fast_track_mcp/crash_events');
  final calls = <MethodCall>[];

  Future<void> emit(Map<String, Object?> record) async {
    final done = Completer<void>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(record),
      (_) => done.complete(),
    );
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method,
        (call) async {
      calls.add(call);
      return null;
    });
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
  });

  tearDown(() async {
    await FastTrackMcpCrashHandler.debugReset();
    await Future<void>.delayed(Duration.zero);
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  test('startup errors are reported and run completes', () async {
    final reports = <Map<String, dynamic>>[];
    FastTrackMcpCrashHandler.debugOnReport =
        (_, properties) async => reports.add(properties);
    await FastTrackMcpCrashHandler.run(() async {
      await Future<void>.delayed(Duration.zero);
      throw StateError('startup failed');
    }).timeout(const Duration(seconds: 2));
    expect(reports, hasLength(1));
    expect(reports.single['type'], 'zone_error');
    expect(reports.single['is_fatal'], true);
  });

  test('independent concurrent errors are retained while reporting is slow',
      () async {
    final release = Completer<void>();
    final messages = <String>[];
    FastTrackMcpCrashHandler.debugOnReport = (_, properties) async {
      messages.add(properties['message'] as String);
      await release.future;
    };
    final pending = List.generate(
        12, (i) => FastTrackMcpCrashHandler.captureMessage('error $i'));
    expect(messages, hasLength(12));
    release.complete();
    await Future.wait(pending);
  });

  test('recursive reporting is suppressed without dropping unrelated errors',
      () async {
    var count = 0;
    FastTrackMcpCrashHandler.debugOnReport = (_, __) async {
      count++;
      await FastTrackMcpCrashHandler.captureMessage('reporter failed');
    };
    await FastTrackMcpCrashHandler.captureMessage('outer');
    await FastTrackMcpCrashHandler.captureMessage('another');
    expect(count, 2);
  });

  test('native startup retries after failure and coalesces simultaneous calls',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var starts = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method,
        (call) async {
      if (call.method == 'startCrash' && ++starts == 1) {
        throw PlatformException(code: 'not_ready');
      }
      return null;
    });
    await FastTrackMcpCrashHandler.ensureNativeInitialized();
    await Future.wait([
      FastTrackMcpCrashHandler.ensureNativeInitialized(),
      FastTrackMcpCrashHandler.ensureNativeInitialized(),
    ]);
    expect(starts, 2);
  });

  test(
      'native ack waits for durable persistence and preserves original context',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final persisted = Completer<bool>();
    Map<String, dynamic>? captured;
    FastTrackMcpCrashHandler.debugPersistCrash = (name,
        {required eventId, required properties, timestamp, sessionId}) async {
      captured = {
        'name': name,
        'id': eventId,
        'timestamp': timestamp,
        'session': sessionId
      };
      return persisted.future;
    };
    await FastTrackMcpCrashHandler.ensureNativeInitialized();
    await emit({
      'crash_id': 'crash-123',
      'message': 'native failure',
      'occurred_at_ms': 1700000000000,
      'session_id': 'previous-session',
      'is_fatal': false,
    });
    expect(calls.where((c) => c.method == 'ackCrash'), isEmpty);
    expect(captured?['name'], 'app_error');
    expect(captured?['id'], 'crash-123');
    expect(captured?['session'], 'previous-session');
    expect(captured?['timestamp'],
        DateTime.fromMillisecondsSinceEpoch(1700000000000));
    persisted.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c.method == 'ackCrash').single.arguments,
        {'crash_id': 'crash-123'});
  });

  test('native record is kept when persistence fails', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FastTrackMcpCrashHandler.debugPersistCrash = (name,
            {required eventId,
            required properties,
            timestamp,
            sessionId}) async =>
        false;
    await FastTrackMcpCrashHandler.ensureNativeInitialized();
    await emit({'crash_id': 'keep-me', 'message': 'disk unavailable'});
    expect(calls.where((c) => c.method == 'ackCrash'), isEmpty);
  });

  test('replayed native records do not enqueue twice after a failed ack',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var writes = 0;
    var acks = 0;
    FastTrackMcpCrashHandler.debugPersistCrash = (name,
        {required eventId, required properties, timestamp, sessionId}) async {
      writes++;
      return true;
    };
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method,
        (call) async {
      if (call.method == 'ackCrash' && ++acks == 1) {
        throw PlatformException(code: 'ack_failed');
      }
      return null;
    });
    await FastTrackMcpCrashHandler.ensureNativeInitialized();
    await emit({'crash_id': 'same-crash', 'is_fatal': false});
    await emit({'crash_id': 'same-crash', 'is_fatal': false});
    expect(writes, 1);
    expect(acks, 2);
  });

  test('custom properties cannot overwrite exception severity or message',
      () async {
    Map<String, dynamic>? captured;
    FastTrackMcpCrashHandler.debugOnReport =
        (_, properties) async => captured = properties;
    await FastTrackMcpCrashHandler.captureException(StateError('original'),
        properties: {'is_fatal': true, 'message': 'overwritten', 'custom': 42});
    expect(captured?['is_fatal'], false);
    expect(captured?['message'], contains('original'));
    expect(captured?['custom'], 42);
  });

  test('pre-init crash persistence does not acknowledge an in-memory event',
      () async {
    expect(
        await FastTracker.persistCrash('app_crash',
            eventId: 'not-durable', properties: {}),
        false);
  });
}
