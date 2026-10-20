import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'sleuth_facade.dart';

/// Windowed Sleuth issue bind for transitions (push stamp → pop diff).
///
/// Sleuth has no public issue push stream; we poll [SleuthFacade.issues] at
/// push/pop and attribute allowlisted *new* memory issues to the popped route.
class SleuthTransitionBinder {
  SleuthTransitionBinder._();
  static final SleuthTransitionBinder instance = SleuthTransitionBinder._();

  /// Master switch (= config `sleuthBindEnabled`).
  bool enabled = true;

  /// Memory-family stableId / title needles (PRD: heap_growing, stream_…).
  static const allowlist = <String>[
    'heap_growing',
    'stream_resource_growth',
    'native_memory_growing',
  ];

  /// routeKey → fingerprints stamped at push (`stableId|title`).
  final Map<String, Set<String>> _stamps = {};

  void clear() => _stamps.clear();

  static String _routeKey(String route) => route.split('#').first;

  static String fingerprint(SleuthIssueItem item) {
    final id = (item.stableId ?? item.id ?? '').trim();
    final title = (item.title ?? item.detail ?? '').trim();
    return '$id|$title';
  }

  static bool isAllowlisted(SleuthIssueItem item) {
    final id = (item.stableId ?? item.id ?? '').toLowerCase();
    final title = (item.title ?? item.detail ?? '').toLowerCase();
    for (final needle in allowlist) {
      if (id == needle || id.contains(needle)) return true;
      if (title.contains(needle.replaceAll('_', ' ')) ||
          title.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  static Map<String, dynamic> shortMap(SleuthIssueItem item) {
    return <String, dynamic>{
      if (item.stableId != null) 'stableId': item.stableId,
      if (item.id != null) 'id': item.id,
      if (item.title != null) 'title': item.title,
      if (item.severity != null) 'severity': item.severity,
      if (item.category != null) 'category': item.category,
      'sourceRoute': true,
    };
  }

  List<SleuthIssueItem> _pollIssues() {
    if (kReleaseMode || !enabled) return const [];
    try {
      final res = SleuthFacade.issues(limit: 80);
      if (!res.isOk || res.data == null) return const [];
      return res.data!.issues;
    } catch (e) {
      debugPrint('[SleuthTransitionBinder] poll failed: $e');
      return const [];
    }
  }

  /// Stamp current allowlisted (+ all) fingerprints for [route] at push.
  void stampPush(String route) {
    if (!enabled || kReleaseMode) return;
    final key = _routeKey(route);
    final issues = _pollIssues();
    final keys = <String>{};
    for (final i in issues) {
      keys.add(fingerprint(i));
    }
    _stamps[key] = keys;
    debugPrint(
      '[SleuthTransitionBinder] stamp $key issues=${keys.length}',
    );
  }

  /// Allowlisted issues present now but not at push stamp for [route].
  List<Map<String, dynamic>> diffSincePush(String route) {
    if (!enabled || kReleaseMode) return const [];
    final key = _routeKey(route);
    final before = _stamps[key] ?? const <String>{};
    final issues = _pollIssues();
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final i in issues) {
      if (!isAllowlisted(i)) continue;
      final fp = fingerprint(i);
      if (before.contains(fp)) continue;
      if (!seen.add(fp)) continue;
      out.add(shortMap(i));
    }
    return out;
  }
}
