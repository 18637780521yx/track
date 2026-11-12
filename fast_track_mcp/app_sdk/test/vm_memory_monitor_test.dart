import 'dart:async';
import 'dart:convert';

import 'package:fast_track_mcp/src/detect/vm_memory_monitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

// Real vm_service JSON-RPC parsing with an in-memory transport. This validates
// isolate attribution, optional Class metadata, and the no-forced-GC contract.
void main() {
  const mib = 1024 * 1024;
  late StreamController<String> inbound;
  late VmService service;
  late VmMemoryMonitor monitor;
  late List<Map<String, dynamic>> signals;
  late List<Map<String, dynamic>> requests;
  var clock = 0;
  var disposed = false;

  setUp(() {
    clock = 0;
    disposed = false;
    inbound = StreamController<String>();
    signals = [];
    requests = [];
    service = VmService(inbound.stream, (message) {
      final request = jsonDecode(message) as Map<String, dynamic>;
      requests.add(request);
      final method = request['method'];
      Map<String, dynamic> result;
      switch (method) {
        case 'streamListen':
          result = {'type': 'Success'};
        case 'getMemoryUsage':
          result = {
            'type': 'MemoryUsage',
            'heapUsage': 100 * mib + clock * 800,
            'heapCapacity': 300 * mib,
            'externalUsage': 0
          };
        case 'getAllocationProfile':
          result = {
            'type': 'AllocationProfile',
            'members': [
              {
                'type': 'ClassHeapStats',
                'class': {
                  'type': '@Class',
                  'id': 'classes/timer',
                  'name': '_Timer'
                },
                'instancesCurrent': clock ~/ 15000,
                'bytesCurrent': 100
              },
              {
                'type': 'ClassHeapStats',
                'class': {
                  'type': '@Class',
                  'id': 'classes/big',
                  'name': 'BigPayload'
                },
                'instancesCurrent': 1,
                'bytesCurrent': 100000
              },
            ]
          };
        case 'getObject':
          result = {
            'type': 'Class',
            'id': 'classes/timer',
            'name': '_Timer',
            'library': {
              'type': '@Library',
              'id': 'libraries/async',
              'uri': 'dart:async',
              'name': 'dart.async'
            }
          };
        default:
          throw StateError('Unexpected RPC: $method');
      }
      inbound.add(jsonEncode(
          {'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
    }, disposeHandler: () async {
      disposed = true;
    });
    monitor = VmMemoryMonitor(
      onSignal: (signal) async => signals.add(signal),
      connectForTest: () async => service,
      isolateForTest: 'isolates/app',
      clockForTest: () => clock,
    );
  });

  tearDown(() async {
    await monitor.stop();
    await inbound.close();
  });

  Future<void> gc(
      {String? isolate = 'isolates/app',
      int? timestamp,
      String type = 'MarkSweep',
      String reason = 'idle',
      int bytes = mib}) async {
    inbound.add(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'streamNotify',
      'params': {
        'streamId': 'GC',
        'event': {
          'type': 'Event',
          'kind': 'GC',
          if (isolate != null)
            'isolate': {
              'type': '@Isolate',
              'id': isolate,
              'name': 'main',
              'number': '1'
            },
          'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
          'gcType': type,
          'reason': reason,
          'new': {'used': 0},
          'old': {'used': bytes},
        },
      }
    }));
    await Future<void>.delayed(Duration.zero);
  }

  test(
      'VM polling enriches growth, resolves resource classes, and never forces GC',
      () async {
    await monitor.start();
    expect(monitor.isConnected, true, reason: jsonEncode(requests));
    for (clock = 5000; clock <= 120000; clock += 5000) {
      await monitor.sampleNow();
    }
    final heap = signals.firstWhere((s) => s['type'] == 'heap_growing');
    expect(heap['leak_confirmed'], false);
    expect((heap['top_classes'] as List).first['class'], 'BigPayload');
    final resource =
        signals.firstWhere((s) => s['type'] == 'stream_resource_growth');
    expect(resource['resource_class'], 'dart:async::_Timer');
    expect(requests.where((r) => r['method'] == 'getObject').length, 1);
    final profileCalls =
        requests.where((r) => r['method'] == 'getAllocationProfile');
    expect(profileCalls.length, 5);
    // vm_service omits gc=false from the wire; absent also means no forced GC.
    expect(
        profileCalls.every(
            (r) => r['params']['gc'] != true && r['params']['gc'] != 'true'),
        true);
    await monitor.stop();
    final count = requests.length;
    await monitor.sampleNow();
    expect(requests.length, count);
    expect(disposed, true);
  });

  test(
      'unrelated, unattributable, and stale GC events cannot confirm retention',
      () async {
    await monitor.start();
    await gc(type: 'Scavenge');
    for (var i = 0; i < 5; i++) {
      clock = 30000 + i * 5000;
      await gc(isolate: 'isolates/worker', bytes: i * 4 * mib);
      await gc(isolate: null, bytes: i * 4 * mib);
      await gc(
          timestamp: DateTime.now().millisecondsSinceEpoch - 60000,
          bytes: i * 4 * mib);
    }
    expect(signals, isEmpty);
    for (var i = 0; i < 3; i++) {
      clock = 60000 + i * 5000;
      await gc(bytes: (10 + i * 4) * mib);
    }
    final floor = signals.single;
    expect(floor['type'], 'heap_retained_growth');
    expect(floor['gc_verified'], true);
    expect(floor['leak_confirmed'], false);
  });

  test('VM connection failure is contained without creating evidence',
      () async {
    await monitor.stop();
    monitor = VmMemoryMonitor(
        onSignal: (signal) async => signals.add(signal),
        connectForTest: () async => throw StateError('VM unavailable'),
        isolateForTest: 'isolates/app');
    await monitor.start();
    expect(monitor.isConnected, false);
    expect(signals, isEmpty);
    // The unused test transport still belongs to the test.
    await service.dispose();
  });
}
