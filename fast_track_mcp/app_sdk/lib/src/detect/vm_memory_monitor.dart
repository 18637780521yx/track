import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate' as isolates;

import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'vm_memory_evidence.dart';

/// Debug/Profile only. Uses the current isolate's VM service, without GC RPCs,
/// timeline hooks, HTTP overrides, or a dependency on Sleuth's controller.
class VmMemoryMonitor {
  VmMemoryMonitor({
    required this.onSignal,
    @visibleForTesting this.connectForTest,
    @visibleForTesting this.isolateForTest,
    @visibleForTesting this.clockForTest,
  });
  final Future<void> Function(Map<String, dynamic>) onSignal;
  final Future<VmService> Function()? connectForTest;
  final String? isolateForTest;
  final int Function()? clockForTest;
  final _evidence = VmMemoryEvidence();
  final _clock = Stopwatch();
  VmService? _service;
  String? _isolate;
  StreamSubscription<Event>? _gcSubscription;
  Timer? _timer;
  bool _stopped = false, _polling = false;
  int _lastProfileMs = -30000;
  List<Map<String, dynamic>> _topClasses = [];
  final _resourceLibraries = <String, String>{};
  int get _now => clockForTest?.call() ?? _clock.elapsedMilliseconds;
  bool get isConnected => !_stopped && _service != null;

  @visibleForTesting
  Future<void> sampleNow() => _poll();

  Future<void> start() async {
    if (kReleaseMode || kIsWeb || _stopped) return;
    try {
      final isolate = isolateForTest ??
          developer.Service.getIsolateId(isolates.Isolate.current);
      if (isolate == null || _stopped) return;
      final factory = connectForTest;
      Future<VmService> connecting;
      if (factory != null) {
        connecting = factory();
      } else {
        final info = await developer.Service.getInfo();
        final uri = info.serverUri;
        if (uri == null || _stopped) return;
        final ws = uri.replace(
            scheme: uri.scheme == 'https' ? 'wss' : 'ws',
            path: '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}ws');
        connecting = vmServiceConnectUri(ws.toString());
      }
      unawaited(connecting.then((service) async {
        if (_stopped) await service.dispose();
      }, onError: (Object _) {}));
      final service = await connecting.timeout(const Duration(seconds: 3));
      if (_stopped) {
        await service.dispose();
        return;
      }
      _service = service;
      _isolate = isolate;
      _clock.start();
      _gcSubscription = service.onGCEvent.listen(_onGc, onError: (Object _) {});
      try {
        await service
            .streamListen(EventStreams.kGC)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Heap polling can still work on VMs without a GC stream.
      }
      if (_stopped) return;
      _timer =
          Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_poll()));
      unawaited(service.onDone.then((_) => stop()));
      await _poll();
    } catch (_) {
      // VM unavailable: keep RSS monitoring. Do not log token-bearing URIs.
      await stop();
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    final subscription = _gcSubscription;
    _gcSubscription = null;
    final service = _service;
    _service = null;
    await subscription?.cancel();
    if (service != null) {
      try {
        await service.dispose();
      } catch (_) {}
    }
  }

  void _onGc(Event event) {
    // Unattributable events cannot strengthen a leak suspicion.
    if (_stopped || event.isolate?.id != _isolate) return;
    final json = event.json;
    if (json == null) return;
    final timestamp = event.timestamp;
    if (timestamp == null ||
        (DateTime.now().millisecondsSinceEpoch - timestamp).abs() > 30000) {
      return;
    }
    int? used(String generation) {
      final data = json[generation];
      return data is Map && data['used'] is num
          ? (data['used'] as num).toInt()
          : null;
    }

    final young = used('new'), old = used('old');
    final signals = _evidence.addGc(
      atMs: _now,
      type: json['gcType']?.toString() ?? '',
      reason: json['reason']?.toString(),
      heapUsedAfter: young != null && old != null ? young + old : null,
    );
    for (final signal in signals) {
      unawaited(_report(signal));
    }
  }

  Future<void> _poll() async {
    final service = _service, isolate = _isolate;
    if (_stopped || _polling || service == null || isolate == null) return;
    _polling = true;
    try {
      final usage = await service
          .getMemoryUsage(isolate)
          .timeout(const Duration(seconds: 3));
      if (_stopped) return;
      final at = _now;
      final heap = usage.heapUsage, external = usage.externalUsage;
      if (heap != null && external != null) {
        for (final signal in _evidence.addHeap(
            atMs: at,
            heapBytes: heap,
            externalBytes: external,
            rssBytes: ProcessInfo.currentRss)) {
          await _report(signal);
        }
      }
      if (at - _lastProfileMs >= 30000) {
        _lastProfileMs = at;
        final profile = await service
            .getAllocationProfile(isolate, gc: false)
            .timeout(const Duration(seconds: 3));
        if (_stopped) return;
        final members = [
          ...?profile.members
        ]..sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));
        _topClasses = members
            .take(8)
            .map((c) => <String, dynamic>{
                  'class': c.classRef?.name,
                  'library': c.classRef?.library?.uri,
                  'instances': c.instancesCurrent,
                  'bytes': c.bytesCurrent,
                })
            .toList();
        final counts = <String, int>{};
        var unresolved = false;
        var lookups = 0;
        for (final c in members) {
          final name = c.classRef?.name ?? '';
          if (!name.contains('StreamController') &&
              !name.contains('StreamSubscription') &&
              !name.contains('Timer')) {
            continue;
          }
          final id = c.classRef?.id;
          var library = c.classRef?.library?.uri ?? _resourceLibraries[id];
          if (library == null && id != null && lookups < 8) {
            lookups++;
            final object = await service
                .getObject(isolate, id)
                .timeout(const Duration(seconds: 2));
            if (_stopped) return;
            if (object is Class) library = object.library?.uri;
            if (library != null && _resourceLibraries.length < 128) {
              _resourceLibraries[id] = library;
            }
          }
          if (library == null) {
            unresolved = true;
            continue;
          }
          if (library != 'dart:async') continue;
          counts['$library::$name'] =
              (counts['$library::$name'] ?? 0) + (c.instancesCurrent ?? 0);
        }
        if (!unresolved) {
          for (final signal in _evidence.addResources(at, counts)) {
            await _report(signal);
          }
        }
      }
    } on TimeoutException {
      // Dispose pending RPCs instead of accumulating them on an unresponsive VM.
      await stop();
    } catch (_) {
      // Missing measurements are unknown, not zero. Polling is bounded and
      // cannot overlap; a failed read never creates growth evidence.
    } finally {
      _polling = false;
    }
  }

  Future<void> _report(Map<String, dynamic> signal) async {
    if (_stopped) return;
    try {
      await onSignal({
        ...signal,
        'top_classes': _topClasses,
        'top_classes_age_ms': _now - _lastProfileMs,
        'vm_gc_forced': false
      });
    } catch (_) {}
  }
}
