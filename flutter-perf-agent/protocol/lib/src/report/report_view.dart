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
      final alertType = _normalizeAlertType(a['type']?.toString());
      events.add({
        'id': 'ev_${idx++}',
        'type': 'alert',
        'at': s['at']?.toString() ?? '',
        'label': _alertLabel(a),
        'ok': false,
        'stepId': sid,
        'route': route,
        'source': _normalizeSource(source),
        'module': _moduleForAlertType(alertType),
        'detail': {
          ...a,
          'type': alertType,
          'alertType': alertType,
          if (a['type'] != null && a['type'].toString() != alertType)
            'legacyType': a['type'],
        },
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
    final alertType = _normalizeAlertType(a['type']?.toString());
    final sid = a['stepId']?.toString();
    final stepRoute =
        sid != null && stepById.containsKey(sid) ? _stepRoute(stepById[sid]!) : null;
    events.add({
      'id': 'ev_${idx++}',
      'type': 'alert',
      'at': _alertAt(a, steps, report),
      'label': _alertLabel(a),
      'ok': false,
      'stepId': sid,
      'route': stepRoute,
      'source': null,
      'module': _moduleForAlertType(alertType),
      'detail': {
        ...a,
        'type': alertType,
        'alertType': alertType,
        if (a['type'] != null && a['type'].toString() != alertType)
          'legacyType': a['type'],
      },
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
    case 'lifecycle':
      return 'lifecycle';
    case 'navigate':
      return 'transition';
    case 'alert':
      return 'page'; // refined by _moduleForAlertType when building
    case 'network':
      return 'network';
    default:
      return 'page';
  }
}

/// Canonical alert types — problem kind only; where it sits is the segment.
/// Legacy `transition_*` names map here for old reports.
String _normalizeAlertType(String? raw) {
  final t = (raw ?? 'alert').trim();
  switch (t) {
    case 'transition_jank':
      // Old reports mixed P90 + jank under one name; keep as jank for display.
      return 'jank';
    case 'transition_memory_leak':
      return 'memory_leak';
    case 'transition_memory_retain_rss':
      return 'memory_retain_rss';
    default:
      return t.isEmpty ? 'alert' : t;
  }
}

String _moduleForAlertType(String alertType) {
  final t = _normalizeAlertType(alertType);
  if (t == 'slow_cold_start') return 'lifecycle';
  // memory_leak / memory_retain_rss usually on navigate steps → transition seg
  // via stepId; flat module hint only.
  if (t == 'memory_leak' || t == 'memory_retain_rss') return 'transition';
  return 'page';
}

/// Short timeline label for an alert map (`type` / `value` / `message`).
String _alertLabel(Map<String, dynamic> a) {
  final type = _normalizeAlertType(a['type']?.toString());
  final value = a['value'];
  switch (type) {
    case 'jank':
      return value != null ? 'jank:+$value' : 'jank';
    case 'memory_increase':
    case 'memory_retain_rss':
      if (value is num) {
        return '$type:+${value.toStringAsFixed(1)}MB';
      }
      return type;
    case 'slow_frame':
      if (value is num) {
        return 'slow_frame:${value.toStringAsFixed(0)}ms';
      }
      return type;
    case 'slow_cold_start':
      if (value is num) {
        return 'slow_cold_start:${value.toStringAsFixed(0)}ms';
      }
      return type;
    case 'memory_leak':
      return 'memory_leak';
    case 'sleuth_issues':
    case 'sleuth_detector':
      return type;
    default:
      final msg = a['message']?.toString();
      if (msg != null && msg.isNotEmpty && msg.length <= 80) return msg;
      return type;
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
/// Prefer: action → network → alert → navigate (same step).
int _eventTypeRank(String? type) {
  switch (type) {
    case 'cold_start':
    case 'lifecycle':
      return 0;
    case 'action':
      return 1;
    case 'network':
      return 2;
    case 'alert':
      return 3;
    case 'navigate':
      return 4;
    case 'screenshot':
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
///
/// Modules: `lifecycle` | `page` | `transition` only. Performance issues are
/// `type=alert` events inlined into page / transition (no `module=alert` card).
List<Map<String, dynamic>> _segmentTimeline(
  List<Map<String, dynamic>> events,
  Map<String, Map<String, dynamic>> stepById,
) {
  final segments = <Map<String, dynamic>>[];
  Map<String, dynamic>? openPage;
  Map<String, dynamic>? lastTransition;
  var segIdx = 0;

  void finalizeCounts(Map<String, dynamic> seg) {
    final evs = seg['events'] as List;
    seg['eventCount'] = evs.length;
    seg['networkCount'] =
        evs.where((e) => (e as Map)['type'] == 'network').length;
    seg['actionCount'] =
        evs.where((e) => (e as Map)['type'] == 'action').length;
    seg['alertCount'] =
        evs.where((e) => (e as Map)['type'] == 'alert').length;
  }

  void flushPage() {
    final page = openPage;
    if (page == null) return;
    finalizeCounts(page);
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

  void appendToPage(Map<String, dynamic> e) {
    final route = e['route']?.toString();
    final pageKey =
        (route != null && route.isNotEmpty) ? route : '(unknown)';
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

  Map<String, dynamic>? transitionForAlert(Map<String, dynamic> e) {
    final sid = e['stepId']?.toString();
    if (sid != null) {
      for (var i = segments.length - 1; i >= 0; i--) {
        final seg = segments[i];
        if (seg['module'] == 'transition' &&
            seg['stepId']?.toString() == sid) {
          return seg;
        }
      }
      if (lastTransition != null &&
          lastTransition!['stepId']?.toString() == sid) {
        return lastTransition;
      }
    }
    // Leak / RSS-retain are only emitted on navigate/pop steps.
    final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? {};
    final alertType = _normalizeAlertType(
      d['alertType']?.toString() ?? d['type']?.toString(),
    );
    if (alertType == 'memory_leak' || alertType == 'memory_retain_rss') {
      return lastTransition;
    }
    return null;
  }

  for (final e in events) {
    final type = e['type']?.toString() ?? 'action';

    // Screenshots are not path narrative this iteration.
    if (type == 'screenshot') continue;

    if (type == 'cold_start' || type == 'lifecycle') {
      flushPage();
      lastTransition = null;
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
      final lifeEvents = <Map<String, dynamic>>[e];
      segments.add({
        'id': 'seg_${segIdx++}',
        'module': 'lifecycle',
        'kind': kind == 'paused' || kind == 'hidden'
            ? 'background'
            : (kind == 'resumed' ? 'foreground' : kind),
        'title': title,
        'at': e['at'],
        'events': lifeEvents,
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
      flushPage();
      final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? {};
      final transition = <String, dynamic>{
        'id': 'seg_${segIdx++}',
        'module': 'transition',
        'title': e['label'] ?? '${d['from'] ?? '?'} → ${d['to'] ?? '?'}',
        'at': e['at'],
        'from': d['from'],
        'to': d['to'],
        'transitionKind': d['transitionKind'] ?? 'unknown',
        'leak': d['leak'],
        'events': <Map<String, dynamic>>[e],
        'stepId': e['stepId'],
      };
      lastTransition = transition;
      segments.add(transition);
      // Open empty landing page immediately (blank card allowed).
      final to = d['to']?.toString();
      if (to != null && to.isNotEmpty) {
        openPage = newPage(to, e);
      }
      continue;
    }

    if (type == 'alert') {
      final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? {};
      final alertType = _normalizeAlertType(
        d['alertType']?.toString() ?? d['type']?.toString(),
      );
      // Cold-start alerts sit on the latest lifecycle segment when possible.
      if (alertType == 'slow_cold_start') {
        Map<String, dynamic>? life;
        for (var i = segments.length - 1; i >= 0; i--) {
          if (segments[i]['module'] == 'lifecycle') {
            life = segments[i];
            break;
          }
        }
        if (life != null) {
          (life['events'] as List).add(e);
          continue;
        }
      }
      final tSeg = transitionForAlert(e);
      if (tSeg != null) {
        (tSeg['events'] as List).add(e);
        continue;
      }
      appendToPage(e);
      continue;
    }

    // action / network → current page
    appendToPage(e);
  }
  flushPage();

  for (final seg in segments) {
    finalizeCounts(seg);
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
