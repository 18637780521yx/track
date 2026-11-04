import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

TransitionLeakProbe _probe({
  List<Map<String, dynamic>> alive = const [],
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
  );
}

void main() {
  tearDown(() {
    TransitionLeakTracker.instance.configure(
      alertOnWeakRef: true,
      requireMultiRound: false,
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
      alerts.where((a) => a.type == 'memory_leak'),
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

  test('alertOnWeakRef false suppresses WeakRef leak alerts', () {
    final t = TransitionLeakTracker.instance;
    t.configure(alertOnWeakRef: false);
    expect(
      t.shouldAlertLeak(
        _probe(alive: [
          {'name': 'X'},
        ]),
      ),
      isFalse,
    );
    expect(t.shouldAlertLeak(_probe()), isFalse);
  });

  test('alertOnRssRetain gate', () {
    final t = TransitionLeakTracker.instance;
    t.configure(
      alertOnWeakRef: false,
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
