import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:flutter_test/flutter_test.dart';

TransitionLeakProbe _probe({
  List<Map<String, dynamic>> alive = const [],
  List<Map<String, dynamic>> sleuthHits = const [],
  bool multi = false,
  List<int> counts = const [1],
}) {
  return TransitionLeakProbe(
    route: '/r',
    alive: alive,
    rssBeforeMb: 10,
    rssAfterMb: 16,
    settleMs: 100,
    roundIndex: counts.length,
    aliveCounts: counts,
    multiRoundConfirmed: multi,
    sleuthHits: sleuthHits,
  );
}

void main() {
  tearDown(() {
    TransitionLeakTracker.instance.configure(
      alertOnWeakRef: true,
      requireMultiRound: false,
      alertOnSleuthOnly: true,
      alertOnRssRetain: true,
      leakVmDeepProbe: false,
    );
  });

  test('requireMultiRound blocks single-round WeakRef alert', () {
    final t = TransitionLeakTracker.instance;
    t.configure(requireMultiRound: true, alertOnWeakRef: true);
    final single = _probe(
      alive: [
        {'name': 'X'},
      ],
      multi: false,
      counts: const [1],
    );
    expect(t.shouldAlertLeak(single), isFalse);
    final alerts = t.alertsForProbe(probe: single, stepId: '1', action: 'a');
    expect(
      alerts.where((a) => a.type == 'transition_memory_leak'),
      isEmpty,
    );

    final multi = _probe(
      alive: [
        {'name': 'X'},
      ],
      multi: true,
      counts: const [1, 1],
    );
    expect(t.shouldAlertLeak(multi), isTrue);
  });

  test('alertOnWeakRef false still allows Sleuth-only', () {
    final t = TransitionLeakTracker.instance;
    t.configure(alertOnWeakRef: false, alertOnSleuthOnly: true);
    expect(
      t.shouldAlertLeak(
        _probe(alive: [
          {'name': 'X'},
        ]),
      ),
      isFalse,
    );
    expect(
      t.shouldAlertLeak(
        _probe(sleuthHits: [
          {'title': 'heap_growing'},
        ]),
      ),
      isTrue,
    );
  });

  test('alertOnRssRetain gate', () {
    final t = TransitionLeakTracker.instance;
    t.configure(
      alertOnWeakRef: false,
      alertOnSleuthOnly: false,
      alertOnRssRetain: false,
      rssRetainMb: 1,
    );
    final p = _probe();
    final alerts = t.alertsForProbe(probe: p, stepId: '1', action: 'a');
    expect(alerts.where((a) => a.type.contains('rss')), isEmpty);
  });

  test('isClosingTransitionKind for modal', () {
    expect(isClosingTransitionKind('pop', fromRoute: '/a', toRoute: '/b'), isTrue);
    expect(isClosingTransitionKind('modal_dialog', fromRoute: '/home'), isFalse);
    expect(
      isClosingTransitionKind('modal_dialog', fromRoute: '#modal/1'),
      isTrue,
    );
  });

  test('tab-only change never probes', () {
    expect(isTabOnlyRouteChange('/home#home', '/home#mine'), isTrue);
    expect(
      isClosingTransitionKind(
        'remove',
        fromRoute: '/home#home',
        toRoute: '/home#mine',
      ),
      isFalse,
    );
    expect(
      isClosingTransitionKind(
        'tab_change',
        fromRoute: '/home#home',
        toRoute: '/home#mine',
      ),
      isFalse,
    );
    expect(
      TransitionLedger.instance.resolveKind(
        from: '/home#home',
        to: '/home#mine',
      ),
      'tab_change',
    );
  });

  test('shell leave still probes on remove', () {
    expect(
      isClosingTransitionKind(
        'remove',
        fromRoute: '/login',
        toRoute: '/home#home',
      ),
      isTrue,
    );
  });
}
