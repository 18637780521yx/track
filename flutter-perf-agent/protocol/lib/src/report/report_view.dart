/// Derive a presentation-friendly `view` from raw report JSON.
///
/// Structure:
/// - `events` — flat chronological events (debug / filters)
/// - `timeline` — **module segments in time order**; each segment embeds its events
///
/// Modules are NOT separate pages below the timeline — they live inside it.
Map<String, dynamic> buildReportView(Map<String, dynamic> report) {
  final steps =
      (report['steps'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final alerts =
      (report['alerts'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final thresholds =
      (report['thresholds'] as Map?)?.cast<String, dynamic>() ?? const {};
  final slowMs = (thresholds['slowRequestMs'] as num?)?.toInt() ?? 300;

  final stepById = <String, Map<String, dynamic>>{
    for (final s in steps)
      if (s['stepId'] != null) s['stepId'].toString(): s,
  };

  final netByStep = <String, Map<String, Map<String, dynamic>>>{};
  for (final s in steps) {
    final sid = s['stepId']?.toString() ?? '';
    final map = <String, Map<String, dynamic>>{};
    final rawNet = s['networkRequests'];
    if (rawNet is List) {
      for (final n in rawNet) {
        if (n is! Map) continue;
        final m = Map<String, dynamic>.from(n);
        map[_netKey(m)] = m;
      }
    }
    netByStep[sid] = map;
  }

  final events = <Map<String, dynamic>>[];
  var idx = 0;

  for (final s in steps) {
    final sid = s['stepId']?.toString() ?? '';
    final route = _stepRoute(s);
    final source = s['source']?.toString() ??
        (s['extra'] is Map
            ? (s['extra'] as Map)['source']?.toString()
            : null) ??
        s['driver']?.toString();
    final isCold =
        s['kind'] == 'cold_start' || s['action']?.toString() == 'cold_start';

    if (isCold) {
      events.add({
        'id': 'ev_${idx++}',
        'type': 'cold_start',
        'at': s['at']?.toString() ??
            s['startedAt']?.toString() ??
            report['startedAt']?.toString() ??
            '',
        'label': '冷启动',
        'ok': s['ok'] != false,
        'stepId': sid,
        'route': route,
        'source': source,
        'module': 'startup',
        'detail': {
          'ttffMs': s['ttffMs'],
          'ttiMs': s['ttiMs'],
          'engineTtffMs': s['engineTtffMs'],
        },
        if (s['screenshotDataUri'] != null)
          'screenshotDataUri': s['screenshotDataUri'],
        if (s['screenshotPath'] != null) 'screenshotPath': s['screenshotPath'],
        'startupPhases': s['startupPhases'],
        'startup': s['startup'],
        'ttffMs': s['ttffMs'],
        'ttiMs': s['ttiMs'],
        'engineTtffMs': s['engineTtffMs'],
      });
    }

    final rawEvents = s['events'];
    if (rawEvents is List && rawEvents.isNotEmpty) {
      for (final e in rawEvents) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final type = m['type']?.toString() ?? 'action';
        var detail = (m['detail'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        if (type == 'network') {
          final full = netByStep[sid]?[_netKey(detail)];
          if (full != null) detail = {...full, ...detail};
        }
        // Prefer where the event actually happened over step.route.
        var eventRoute = route;
        final detailRoute = detail['route']?.toString();
        if (detailRoute != null && detailRoute.isNotEmpty) {
          eventRoute = detailRoute;
        } else if (type == 'navigate') {
          final from = detail['from']?.toString();
          if (from != null && from.isNotEmpty) eventRoute = from;
        } else if (type == 'screenshot') {
          // Legacy: post-nav shot still tagged step.route=/login — use navigate.to.
          final to = _navigateToInStep(rawEvents);
          if (to != null && to.isNotEmpty) {
            final shotAt = DateTime.tryParse(m['at']?.toString() ?? '');
            final navAt = _navigateAtInStep(rawEvents);
            if (shotAt != null &&
                navAt != null &&
                !shotAt.isBefore(navAt)) {
              eventRoute = to;
            }
          }
        }
        events.add({
          'id': 'ev_${idx++}',
          'type': type,
          'at': m['at']?.toString() ?? '',
          'label': m['label']?.toString() ?? type,
          'ok': m['ok'] != false,
          'stepId': sid,
          'route': eventRoute,
          'source': source,
          'module': _moduleForEventType(type),
          'detail': detail,
          if (m['screenshotDataUri'] != null)
            'screenshotDataUri': m['screenshotDataUri'],
          if (m['screenshotPath'] != null)
            'screenshotPath': m['screenshotPath'],
        });
      }
    } else if (!isCold) {
      final hasShot = (s['screenshotDataUri'] != null &&
              s['screenshotDataUri'].toString().isNotEmpty) ||
          (s['screenshotPath'] != null &&
              s['screenshotPath'].toString().isNotEmpty);
      if (hasShot) {
        events.add({
          'id': 'ev_${idx++}',
          'type': 'screenshot',
          'at': s['at']?.toString() ?? '',
          'label': '步骤截图',
          'ok': true,
          'stepId': sid,
          'route': route,
          'source': source,
          'module': 'page',
          'detail': const <String, dynamic>{},
          if (s['screenshotDataUri'] != null)
            'screenshotDataUri': s['screenshotDataUri'],
          if (s['screenshotPath'] != null)
            'screenshotPath': s['screenshotPath'],
        });
      }
    }

    final stepAlerts =
        (s['alerts'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    for (final a in stepAlerts) {
      events.add({
        'id': 'ev_${idx++}',
        'type': 'alert',
        'at': s['at']?.toString() ?? '',
        'label': a['message']?.toString() ?? a['type']?.toString() ?? 'alert',
        'ok': false,
        'stepId': sid,
        'route': route,
        'source': source,
        'module': 'alert',
        'detail': a,
      });
    }
  }

  final seenAlertKeys = <String>{};
  for (final t in events) {
    if (t['type'] == 'alert') {
      final d = t['detail'];
      if (d is Map) {
        seenAlertKeys.add('${d['type']}|${d['stepId']}|${d['message']}');
      }
    }
  }
  for (final a in alerts) {
    final key = '${a['type']}|${a['stepId']}|${a['message']}';
    if (seenAlertKeys.contains(key)) continue;
    events.add({
      'id': 'ev_${idx++}',
      'type': 'alert',
      'at': _alertAt(a, steps, report),
      'label': a['message']?.toString() ?? a['type']?.toString() ?? 'alert',
      'ok': false,
      'stepId': a['stepId']?.toString(),
      'route': null,
      'source': null,
      'module': 'alert',
      'detail': a,
    });
  }

  // Transition into route X must precede activity already stamped on X
  // (e.g. home/list fired before navigate was recorded at step end).
  _clampNavigateBeforeDestination(events);

  // Chronological by real event time (gesture / request start / shot).
  events.sort((a, b) {
    final ta = DateTime.tryParse(a['at']?.toString() ?? '');
    final tb = DateTime.tryParse(b['at']?.toString() ?? '');
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    final byTime = ta.compareTo(tb);
    if (byTime != 0) return byTime;
    // Stable tie-break only when timestamps equal.
    return _eventTypeRank(a['type']?.toString())
        .compareTo(_eventTypeRank(b['type']?.toString()));
  });

  final timeline = _segmentTimeline(events, stepById);
  final perf = _sessionPerf(steps);
  final netStats = _netStats(events, slowMs);

  return {
    'events': events,
    'timeline': timeline,
    'stats': {
      'eventCount': events.length,
      'segmentCount': timeline.length,
      ...netStats,
      ...perf,
    },
  };
}

String _moduleForEventType(String type) {
  switch (type) {
    case 'cold_start':
      return 'startup';
    case 'navigate':
      return 'transition';
    case 'alert':
      return 'alert';
    case 'network':
      return 'network';
    default:
      return 'page';
  }
}

/// Tie-break only when two events share the same [at] timestamp.
int _eventTypeRank(String? type) {
  switch (type) {
    case 'cold_start':
      return 0;
    case 'action':
      return 1;
    case 'navigate':
      return 2;
    case 'network':
      return 3;
    case 'screenshot':
      return 4;
    case 'alert':
      return 5;
    default:
      return 6;
  }
}

String? _navigateToInStep(List rawEvents) {
  for (final e in rawEvents) {
    if (e is! Map) continue;
    if (e['type']?.toString() != 'navigate') continue;
    final d = e['detail'];
    if (d is Map) {
      final to = d['to']?.toString();
      if (to != null && to.isNotEmpty) return to;
    }
  }
  return null;
}

DateTime? _navigateAtInStep(List rawEvents) {
  for (final e in rawEvents) {
    if (e is! Map) continue;
    if (e['type']?.toString() != 'navigate') continue;
    return DateTime.tryParse(e['at']?.toString() ?? '');
  }
  return null;
}

/// If navigate was stamped after dest activity of **this** transition
/// (e.g. network on landing fired before navigate was recorded), pull it back.
///
/// Lower bound is the previous navigate (by original time). Never clamp against
/// earlier visits to the same route — that created orphan leading transitions.
void _clampNavigateBeforeDestination(List<Map<String, dynamic>> events) {
  final navs = <Map<String, dynamic>>[
    for (final e in events)
      if (e['type']?.toString() == 'navigate') e,
  ];
  final origAt = <Map<String, dynamic>, DateTime>{};
  for (final nav in navs) {
    final t = DateTime.tryParse(nav['at']?.toString() ?? '');
    if (t != null) origAt[nav] = t;
  }
  navs.retainWhere(origAt.containsKey);
  navs.sort((a, b) => origAt[a]!.compareTo(origAt[b]!));

  for (var i = 0; i < navs.length; i++) {
    final nav = navs[i];
    final navAt = origAt[nav]!;
    final detail =
        (nav['detail'] as Map?)?.cast<String, dynamic>() ?? const {};
    final to = detail['to']?.toString();
    if (to == null || to.isEmpty) continue;

    final lower = i > 0
        ? origAt[navs[i - 1]]!
        : navAt.subtract(const Duration(seconds: 5));

    DateTime? earliestOnDest;
    for (final e in events) {
      if (identical(e, nav)) continue;
      final et = e['type']?.toString();
      if (et == 'navigate' || et == 'alert') continue;
      if (e['route']?.toString() != to) continue;
      final t = DateTime.tryParse(e['at']?.toString() ?? '');
      if (t == null) continue;
      if (!t.isAfter(lower)) continue;
      if (!t.isBefore(navAt)) continue;
      if (earliestOnDest == null || t.isBefore(earliestOnDest)) {
        earliestOnDest = t;
      }
    }
    if (earliestOnDest == null) continue;
    nav['at'] = earliestOnDest
        .subtract(const Duration(milliseconds: 1))
        .toIso8601String();
  }
}

/// Walk flat events → chronological module segments (modules live inside timeline).
List<Map<String, dynamic>> _segmentTimeline(
  List<Map<String, dynamic>> events,
  Map<String, Map<String, dynamic>> stepById,
) {
  final segments = <Map<String, dynamic>>[];
  Map<String, dynamic>? openPage;
  var segIdx = 0;

  void flushPage() {
    final page = openPage;
    if (page == null) return;
    final evs = page['events'] as List;
    if (evs.isEmpty) {
      openPage = null;
      return;
    }
    page['eventCount'] = evs.length;
    page['networkCount'] =
        evs.where((e) => (e as Map)['type'] == 'network').length;
    page['alertCount'] = evs.where((e) => (e as Map)['type'] == 'alert').length;
    segments.add(page);
    openPage = null;
  }

  Map<String, dynamic> newPage(String route, Map<String, dynamic> first) {
    return {
      'id': 'seg_${segIdx++}',
      'module': 'page',
      'title': route,
      'route': route,
      'at': first['at'],
      'events': <Map<String, dynamic>>[],
      'stepIds': <String>{},
    };
  }

  for (final e in events) {
    final type = e['type']?.toString() ?? 'action';

    if (type == 'cold_start') {
      flushPage();
      segments.add({
        'id': 'seg_${segIdx++}',
        'module': 'startup',
        'title': 'App 启动',
        'at': e['at'],
        'events': [e],
        'ttffMs': e['ttffMs'] ?? (e['detail'] as Map?)?['ttffMs'],
        'ttiMs': e['ttiMs'] ?? (e['detail'] as Map?)?['ttiMs'],
        'engineTtffMs':
            e['engineTtffMs'] ?? (e['detail'] as Map?)?['engineTtffMs'],
        'startupPhases': e['startupPhases'],
        'startup': e['startup'],
        'screenshotDataUri': e['screenshotDataUri'],
        'screenshotPath': e['screenshotPath'],
        'stepId': e['stepId'],
      });
      continue;
    }

    if (type == 'navigate') {
      flushPage();
      final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? {};
      segments.add({
        'id': 'seg_${segIdx++}',
        'module': 'transition',
        'title': e['label'] ?? '${d['from'] ?? '?'} → ${d['to'] ?? '?'}',
        'at': e['at'],
        'from': d['from'],
        'to': d['to'],
        'transitionKind': d['transitionKind'] ?? 'unknown',
        'leak': d['leak'],
        'events': [e],
        'stepId': e['stepId'],
      });
      continue;
    }

    // Alerts / network / action / screenshot attach to current page when possible.
    final route = e['route']?.toString();
    final pageKey =
        (route != null && route.isNotEmpty) ? route : '(unknown)';

    if (type == 'alert' && openPage == null && route == null) {
      segments.add({
        'id': 'seg_${segIdx++}',
        'module': 'alert',
        'title': e['label'] ?? '告警',
        'at': e['at'],
        'events': [e],
        'stepId': e['stepId'],
      });
      continue;
    }

    if (openPage == null || openPage!['route'] != pageKey) {
      flushPage();
      openPage = newPage(pageKey, e);
    }
    (openPage!['events'] as List).add(e);
    final sid = e['stepId']?.toString();
    if (sid != null) {
      (openPage!['stepIds'] as Set<String>).add(sid);
    }
  }
  flushPage();

  // Attach per-page diff summary from steps that *originated* on this page.
  // A login tap may also capture dest-route nets (home/list); those stepIds
  // appear under /home#home events but must not show "login_button" here.
  for (final seg in segments) {
    if (seg['module'] != 'page') continue;
    final pageRoute = seg['route']?.toString() ?? '';
    final ids = (seg['stepIds'] as Set<String>?) ?? {};
    final ownedIds = <String>[];
    final diffs = <Map<String, dynamic>>[];
    for (final id in ids) {
      final s = stepById[id];
      if (s == null) continue;
      final stepRoute = _stepRoute(s);
      if (pageRoute.isNotEmpty &&
          stepRoute != null &&
          stepRoute.isNotEmpty &&
          stepRoute != pageRoute) {
        continue;
      }
      ownedIds.add(id);
      final diff = (s['diff'] as Map?)?.cast<String, dynamic>() ?? {};
      diffs.add({
        'stepId': id,
        'cause': s['cause'] ??
            (s['extra'] is Map ? (s['extra'] as Map)['cause'] : null) ??
            s['action'],
        'durationMs': diff['durationMs'],
        'memoryDeltaMb': diff['memoryDeltaMb'],
        'jankDelta': diff['jankDelta'],
        'fpsAfter': diff['fpsAfter'],
      });
    }
    seg['stepIds'] = ownedIds;
    seg['diffs'] = diffs;
  }

  return segments;
}

Map<String, dynamic> _netStats(List<Map<String, dynamic>> events, int slowMs) {
  var count = 0;
  var slow = 0;
  var fail = 0;
  for (final e in events) {
    if (e['type'] != 'network') continue;
    count++;
    final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? {};
    final duration = (d['durationMs'] as num?)?.toInt();
    final status = (d['statusCode'] as num?)?.toInt() ?? 0;
    if (duration != null && duration >= slowMs) slow++;
    if (status <= 0 || status >= 400) fail++;
  }
  return {
    'networkCount': count,
    'slowNetworkCount': slow,
    'failNetworkCount': fail,
    'slowRequestMs': slowMs,
  };
}

Map<String, dynamic> _sessionPerf(List<Map<String, dynamic>> steps) {
  double? fpsSum;
  var fpsN = 0;
  var jankTotal = 0;
  double? rssPeak;
  for (final s in steps) {
    if (s['kind'] == 'cold_start' || s['action']?.toString() == 'cold_start') {
      continue;
    }
    final diff = (s['diff'] as Map?)?.cast<String, dynamic>() ?? {};
    final after = (diff['after'] as Map?)?.cast<String, dynamic>();
    final fps = (diff['fpsAfter'] as num?)?.toDouble() ??
        (after?['avgFps'] as num?)?.toDouble();
    if (fps != null) {
      fpsSum = (fpsSum ?? 0) + fps;
      fpsN++;
    }
    final jank = (diff['jankDelta'] as num?)?.toInt();
    if (jank != null && jank > 0) jankTotal += jank;
    final rss = (after?['rssMb'] as num?)?.toDouble();
    if (rss != null) {
      final peak = rssPeak;
      rssPeak = peak == null ? rss : (rss > peak ? rss : peak);
    }
  }
  final peak = rssPeak;
  return {
    'avgFps':
        fpsN > 0 ? double.parse((fpsSum! / fpsN).toStringAsFixed(1)) : null,
    'jankTotal': jankTotal,
    'rssPeakMb':
        peak == null ? null : double.parse(peak.toStringAsFixed(2)),
  };
}

String? _stepRoute(Map<String, dynamic> s) {
  final r = s['route']?.toString();
  if (r != null && r.trim().isNotEmpty) return r;
  final action = s['action']?.toString() ?? '';
  if (action.startsWith('route:')) return action.substring(6);
  return null;
}

String _netKey(Map<String, dynamic> m) =>
    '${m['startedAt']}|${m['method']}|${m['url']}|${m['statusCode']}';

String _alertAt(
  Map<String, dynamic> a,
  List<Map<String, dynamic>> steps,
  Map<String, dynamic> report,
) {
  final sid = a['stepId']?.toString();
  if (sid != null) {
    for (final s in steps) {
      if (s['stepId']?.toString() == sid) {
        return s['at']?.toString() ?? report['startedAt']?.toString() ?? '';
      }
    }
  }
  return report['endedAt']?.toString() ??
      report['startedAt']?.toString() ??
      '';
}
