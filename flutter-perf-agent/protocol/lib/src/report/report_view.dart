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
        'module': 'lifecycle',
        'detail': {
          'kind': 'cold_start',
          'ttffMs': s['ttffMs'],
          'ttiMs': s['ttiMs'],
          'engineTtffMs': s['engineTtffMs'],
        },
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
        // Screenshots deferred from path narrative (still in raw steps if needed).
        if (type == 'screenshot') continue;

        var label = m['label']?.toString() ?? type;
        if (type == 'action') {
          label = _normalizeActionLabel(label, detail: detail);
        } else if (type == 'lifecycle') {
          final kind = detail['kind']?.toString() ?? label;
          label = switch (kind) {
            'background' || 'paused' || 'hidden' => 'App 进入后台',
            'foreground' || 'resumed' => 'App 进入前台',
            'cold_start' => 'App 启动',
            _ => label,
          };
        }

        events.add({
          'id': 'ev_${idx++}',
          'type': type == 'cold_start' ? 'cold_start' : type,
          'at': m['at']?.toString() ?? '',
          'label': label,
          'ok': m['ok'] != false,
          'stepId': sid,
          'route': eventRoute,
          'source': _normalizeSource(source),
          'module': _moduleForEventType(type),
          'detail': detail,
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

  final timeline = _segmentTimeline(events, stepById, slowMs: slowMs);
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
    case 'lifecycle':
      return 'lifecycle';
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

String _normalizeSource(String? raw) {
  final s = (raw ?? '').toLowerCase().trim();
  if (s == 'manual' || s == 'user' || s == 'manual_gesture') return 'manual';
  // flutter_skill / mcp / bridge / empty → mcp
  return 'mcp';
}

/// Normalize action labels to `tap:` / `input:` / `scroll:` forms.
String _normalizeActionLabel(String? raw, {Map<String, dynamic>? detail}) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return 'action';
  final lower = s.toLowerCase();
  if (lower.startsWith('tap:') ||
      lower.startsWith('input:') ||
      lower.startsWith('scroll:')) {
    final mEq = RegExp(
      r'^input:(password|pwd|passwd)\s*=\s*.+$',
      caseSensitive: false,
    ).firstMatch(s);
    if (mEq != null) return 'input:${mEq.group(1)}=***';
    final mBare = RegExp(
      r'^input:(password|pwd|passwd)$',
      caseSensitive: false,
    ).firstMatch(s);
    if (mBare != null) return 'input:${mBare.group(1)}=***';
    return s;
  }
  if (lower.startsWith('tap:') || lower.contains('tap:')) return s;
  // Common demo labels: tap:login, input:password, scroll…
  if (lower.startsWith('input')) {
    final field = detail?['key']?.toString() ??
        detail?['field']?.toString() ??
        (s.contains(':') ? s.split(':').skip(1).join(':') : 'field');
    final sensitive = RegExp(r'pass|pwd', caseSensitive: false).hasMatch(field);
    final val = detail?['text']?.toString() ?? detail?['value']?.toString();
    if (sensitive) return 'input:$field=***';
    if (val != null && val.isNotEmpty) return 'input:$field=$val';
    return 'input:$field';
  }
  if (lower.startsWith('scroll')) {
    final dir = detail?['direction']?.toString() ??
        (lower.contains('up') || lower.contains('↑') ? '↑' : '↓');
    final delta = detail?['delta'] ?? detail?['dy'] ?? detail?['offset'];
    return delta != null ? 'scroll:$dir$delta' : 'scroll:$dir';
  }
  if (lower.startsWith('tap') || s.contains('button') || s.contains('登录')) {
    final target = detail?['key']?.toString() ??
        detail?['text']?.toString() ??
        (s.contains(':') ? s.split(':').skip(1).join(':').trim() : s);
    return 'tap:$target';
  }
  // Fallback: keep as action:label
  if (s.contains(':')) return s;
  return 'action:$s';
}

/// Tie-break only when two events share the same [at] timestamp.
int _eventTypeRank(String? type) {
  switch (type) {
    case 'cold_start':
    case 'lifecycle':
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

/// Walk flat events → chronological module segments (page-level path).
List<Map<String, dynamic>> _segmentTimeline(
  List<Map<String, dynamic>> events,
  Map<String, Map<String, dynamic>> stepById, {
  int slowMs = 300,
}) {
  final segments = <Map<String, dynamic>>[];
  Map<String, dynamic>? openPage;
  Map<String, dynamic>? openReport;
  String? lastPageRoute;
  String? lastPageId;
  var segIdx = 0;

  Map<String, dynamic> pageSummaryOf(Map<String, dynamic> page) {
    final evs = (page['events'] as List).cast<Map>();
    var slow = 0;
    DateTime? t0;
    DateTime? t1;
    for (final e in evs) {
      final at = DateTime.tryParse(e['at']?.toString() ?? '');
      if (at != null) {
        t0 = t0 == null || at.isBefore(t0) ? at : t0;
        t1 = t1 == null || at.isAfter(t1) ? at : t1;
      }
      if (e['type'] == 'network') {
        final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? {};
        final dur = (d['durationMs'] as num?)?.toInt();
        if (dur != null && dur >= slowMs) slow++;
      }
    }
    double? memDelta;
    final ids = (page['stepIds'] as Set<String>?) ?? {};
    for (final id in ids) {
      final s = stepById[id];
      if (s == null) continue;
      final diff = (s['diff'] as Map?)?.cast<String, dynamic>() ?? {};
      final m = (diff['memoryDeltaMb'] as num?)?.toDouble();
      if (m != null) memDelta = (memDelta ?? 0) + m;
    }
    final dwellMs =
        (t0 != null && t1 != null) ? t1.difference(t0).inMilliseconds : null;
    return {
      'dwellMs': dwellMs,
      'actionCount': page['actionCount'] ?? 0,
      'networkCount': page['networkCount'] ?? 0,
      'slowRequestCount': slow,
      if (memDelta != null) 'memoryDeltaMb': double.parse(memDelta.toStringAsFixed(2)),
    };
  }

  bool summaryWorthShowing(Map<String, dynamic>? summary) {
    if (summary == null) return false;
    final actions = (summary['actionCount'] as num?)?.toInt() ?? 0;
    final nets = (summary['networkCount'] as num?)?.toInt() ?? 0;
    final slow = (summary['slowRequestCount'] as num?)?.toInt() ?? 0;
    return actions > 0 || nets > 0 || slow > 0 || summary['memoryDeltaMb'] != null;
  }

  void flushPage() {
    final page = openPage;
    if (page == null) return;
    final evs = page['events'] as List;
    // Empty page cards are kept (path continuity after navigate).
    page['eventCount'] = evs.length;
    page['networkCount'] =
        evs.where((e) => (e as Map)['type'] == 'network').length;
    page['actionCount'] =
        evs.where((e) => (e as Map)['type'] == 'action').length;
    page['alertCount'] = 0;
    lastPageRoute = page['route']?.toString();
    lastPageId = page['id']?.toString();
    segments.add(page);
    openPage = null;
  }

  void flushReport() {
    final report = openReport;
    if (report == null) return;
    final evs = report['events'] as List;
    final summary =
        (report['pageSummary'] as Map?)?.cast<String, dynamic>();
    if (evs.isEmpty && !summaryWorthShowing(summary)) {
      openReport = null;
      return;
    }
    report['eventCount'] = evs.length;
    report['ownerRoute'] = lastPageRoute;
    report['pageSegId'] = lastPageId;
    segments.add(report);
    openReport = null;
  }

  void ensureReport(Map<String, dynamic> first) {
    openReport ??= {
      'id': 'seg_${segIdx++}',
      'module': 'alert',
      'title': '性能报告',
      'at': first['at'],
      'events': <Map<String, dynamic>>[],
    };
  }

  void flushPageThenReport() {
    final page = openPage;
    if (page != null) {
      page['eventCount'] = (page['events'] as List).length;
      page['networkCount'] = (page['events'] as List)
          .where((e) => (e as Map)['type'] == 'network')
          .length;
      page['actionCount'] = (page['events'] as List)
          .where((e) => (e as Map)['type'] == 'action')
          .length;
      final summary = pageSummaryOf(page);
      if (summaryWorthShowing(summary) ||
          (openReport != null &&
              ((openReport!['events'] as List).isNotEmpty))) {
        ensureReport(page);
        openReport!['pageSummary'] = summary;
      }
    }
    flushPage();
    flushReport();
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

    // Screenshots are not path narrative this iteration.
    if (type == 'screenshot') continue;

    if (type == 'cold_start' || type == 'lifecycle') {
      flushPageThenReport();
      final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? {};
      final kind = type == 'cold_start'
          ? 'cold_start'
          : (d['kind']?.toString() ?? 'foreground');
      final title = switch (kind) {
        'cold_start' => 'App 启动',
        'background' || 'paused' || 'hidden' => 'App 进入后台',
        'foreground' || 'resumed' => 'App 进入前台',
        _ => e['label']?.toString() ?? '生命周期',
      };
      segments.add({
        'id': 'seg_${segIdx++}',
        'module': 'lifecycle',
        'kind': kind == 'paused' || kind == 'hidden'
            ? 'background'
            : (kind == 'resumed' ? 'foreground' : kind),
        'title': title,
        'at': e['at'],
        'events': [e],
        'route': d['route'] ?? e['route'],
        'backgroundMs': d['backgroundMs'],
        'ttffMs': e['ttffMs'] ?? d['ttffMs'],
        'ttiMs': e['ttiMs'] ?? d['ttiMs'],
        'engineTtffMs': e['engineTtffMs'] ?? d['engineTtffMs'],
        'startupPhases': e['startupPhases'],
        'startup': e['startup'],
        'stepId': e['stepId'],
      });
      continue;
    }

    if (type == 'navigate') {
      flushPageThenReport();
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
      // Open empty landing page immediately (blank card allowed).
      final to = d['to']?.toString();
      if (to != null && to.isNotEmpty) {
        openPage = newPage(to, e);
      }
      continue;
    }

    if (type == 'alert') {
      ensureReport(e);
      (openReport!['events'] as List).add(e);
      continue;
    }

    // action / network → current page
    final route = e['route']?.toString();
    final pageKey =
        (route != null && route.isNotEmpty) ? route : '(unknown)';

    if (openPage == null || openPage!['route'] != pageKey) {
      flushPage(); // keep pending perf until boundary
      openPage = newPage(pageKey, e);
    }
    (openPage!['events'] as List).add(e);
    final sid = e['stepId']?.toString();
    if (sid != null) {
      (openPage!['stepIds'] as Set<String>).add(sid);
    }
  }
  flushPageThenReport();

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
