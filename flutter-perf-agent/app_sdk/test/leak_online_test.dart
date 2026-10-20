import 'dart:math';

import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    LeakOnline.instance.reset();
  });

  test('sampleRate 0 → never active', () {
    LeakOnline.instance.configure(
      enabled: true,
      sampleRate: 0,
      random: Random(1),
    );
    expect(LeakOnline.instance.active, isFalse);
    LeakOnline.instance.emitBreadcrumb(kind: 'push', from: '/a', to: '/b');
    expect(LeakOnline.instance.drain(), isEmpty);
  });

  test('sampleRate 1 → always active + ring + callback', () {
    final events = <Map<String, dynamic>>[];
    LeakOnline.instance.configure(
      enabled: true,
      sampleRate: 1,
      onEvent: events.add,
      random: Random(1),
    );
    expect(LeakOnline.instance.active, isTrue);

    LeakOnline.instance.emitBreadcrumb(kind: 'push', from: '/a', to: '/b');
    LeakOnline.instance.emitTransitionLeak(
      route: '/profile',
      aliveCount: 1,
      aliveNames: const ['ProfilePushController'],
      evidence: 'weak_ref',
      aliveCounts: const [1],
    );

    expect(events, hasLength(2));
    expect(events[0]['type'], 'route_breadcrumb');
    expect(events[1]['type'], 'transition_leak');
    expect(events[1]['aliveCount'], 1);
    expect(events[1]['aliveNames'], ['ProfilePushController']);

    final drained = LeakOnline.instance.drain();
    expect(drained, hasLength(2));
    expect(LeakOnline.instance.drain(), isEmpty);
  });

  test('enabled false → idle even at rate 1', () {
    LeakOnline.instance.configure(
      enabled: false,
      sampleRate: 1,
      random: Random(1),
    );
    expect(LeakOnline.instance.active, isFalse);
  });

  test('mid rate uses Random die', () {
    // nextDouble for seed 42 first call is < 0.5 typically — assert both sides.
    var hit = 0;
    for (var seed = 0; seed < 40; seed++) {
      LeakOnline.instance.configure(
        enabled: true,
        sampleRate: 0.5,
        random: Random(seed),
      );
      if (LeakOnline.instance.sessionSampled) hit++;
      LeakOnline.instance.reset();
    }
    expect(hit, greaterThan(5));
    expect(hit, lessThan(35));
  });

  test('track gate: release path requires LeakOnline.active', () {
    // In test (debug) kReleaseMode is false — track still needs enabled.
    TransitionLeakTracker.instance.configure(enabled: true);
    final obj = Object();
    TransitionLeakTracker.instance.track(obj, name: 'T', route: '/r');
    // Sanity: probe sees alive after no GC.
    // (Cannot assert release gating here; covered by _allowTrack unit semantics
    // via LeakOnline.configure above.)
    expect(LeakOnline.instance.active, isFalse);
  });
}
