import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Lightweight online (release) leak sampling: breadcrumbs + pop probe events.
///
/// Host apps wire [onEvent] to their analytics/crash pipeline. No HTTP upload
/// is built into the SDK.
class LeakOnline {
  LeakOnline._();
  static final LeakOnline instance = LeakOnline._();

  static const int maxRing = 64;

  bool enabled = false;
  double sampleRate = 0;
  bool sessionSampled = false;
  void Function(Map<String, dynamic> event)? onEvent;

  final ListQueue<Map<String, dynamic>> _ring =
      ListQueue<Map<String, dynamic>>();

  final Random _random = Random();

  /// True when this process session was sampled and online mode is on.
  bool get active => enabled && sessionSampled;

  /// Configure and roll the session die. Call once from [PerfAgent.ensureInitialized].
  void configure({
    required bool enabled,
    required double sampleRate,
    void Function(Map<String, dynamic> event)? onEvent,
    Random? random,
  }) {
    this.enabled = enabled;
    this.sampleRate = sampleRate.clamp(0.0, 1.0);
    this.onEvent = onEvent;
    if (!enabled || this.sampleRate <= 0) {
      sessionSampled = false;
    } else if (this.sampleRate >= 1.0) {
      sessionSampled = true;
    } else {
      sessionSampled = (random ?? _random).nextDouble() < this.sampleRate;
    }
    debugPrint(
      '[LeakOnline] enabled=$enabled rate=${this.sampleRate} '
      'sampled=$sessionSampled',
    );
  }

  void reset() {
    enabled = false;
    sampleRate = 0;
    sessionSampled = false;
    onEvent = null;
    _ring.clear();
  }

  void emit(Map<String, dynamic> event) {
    if (!active) return;
    final stamped = <String, dynamic>{
      ...event,
      'at': event['at'] ?? DateTime.now().toIso8601String(),
    };
    _ring.addLast(stamped);
    while (_ring.length > maxRing) {
      _ring.removeFirst();
    }
    try {
      onEvent?.call(Map<String, dynamic>.from(stamped));
    } catch (e) {
      debugPrint('[LeakOnline] onEvent failed: $e');
    }
  }

  /// Snapshot and clear the ring buffer (for host flush).
  List<Map<String, dynamic>> drain() {
    final out = _ring.map((e) => Map<String, dynamic>.from(e)).toList();
    _ring.clear();
    return out;
  }

  /// Current buffer without clearing.
  List<Map<String, dynamic>> peek() =>
      _ring.map((e) => Map<String, dynamic>.from(e)).toList(growable: false);

  void emitBreadcrumb({
    required String kind,
    String? from,
    String? to,
  }) {
    emit({
      'type': 'route_breadcrumb',
      'kind': kind,
      'from': from,
      'to': to,
    });
  }

  void emitTransitionLeak({
    required String route,
    required int aliveCount,
    required List<String> aliveNames,
    required String evidence,
    required List<int> aliveCounts,
    bool multiRoundConfirmed = false,
  }) {
    emit({
      'type': 'transition_leak',
      'route': route,
      'aliveCount': aliveCount,
      'aliveNames': aliveNames,
      'evidence': evidence,
      'aliveCounts': aliveCounts,
      'multiRoundConfirmed': multiRoundConfirmed,
    });
  }
}
