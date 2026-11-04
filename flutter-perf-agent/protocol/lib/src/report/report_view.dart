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
  final sleuthPerfOn = _thresholdFlag(thresholds, 'sleuthPerfEnabled',
      defaultWhenMissing: true);
  final rssAlertOn = _thresholdFlag(
    thresholds,
    'memoryIncreaseAlertEnabled',
    defaultWhenMissing: true,
  );

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
        // Cold-start step already emitted a synthetic event with TTFF/phases —
        // skip the journal's duplicate cold_start / lifecycle:cold_start.
        if (isCold &&
            (type == 'cold_start' ||
                (type == 'lifecycle' &&
                    detail['kind']?.toString() == 'cold_start'))) {
          continue;
        }

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
          if (m['screenshotPath'] != null)
            'screenshotPath': m['screenshotPath'],
          if (m['screenshotDataUri'] != null)
            'screenshotDataUri': m['screenshotDataUri'],
        });
      }
    }

    // Step-level cover when chapter has a shot but no nested screenshot event.
    final hadShotEvent = rawEvents is List &&
        rawEvents.any(
          (e) => e is Map && e['type']?.toString() == 'screenshot',
        );
    if (!hadShotEvent &&
        (s['screenshotDataUri'] != null || s['screenshotPath'] != null)) {
      final coverRoute = route ?? '(unknown)';
      events.add({
        'id': 'ev_${idx++}',
        'type': 'screenshot',
        'at': s['at']?.toString() ?? '',
        'label': '页面截图',
        'ok': true,
        'stepId': sid,
        'route': coverRoute,
        'source': _normalizeSource(source),
        'module': 'page',
        'detail': {
          if (coverRoute != '(unknown)') 'route': coverRoute,
          'fromStep': true,
        },
        if (s['screenshotPath'] != null) 'screenshotPath': s['screenshotPath'],
        if (s['screenshotDataUri'] != null)
          'screenshotDataUri': s['screenshotDataUri'],
      });
    }

    final stepAlerts =
        (s['alerts'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    for (final raw in stepAlerts) {
      for (final a in expandBagAlerts(raw, expandSleuthBags: sleuthPerfOn)) {
        final alertType = _normalizeAlertType(a['type']?.toString());
        if (_shouldHideAlert(
          alertType,
          sleuthPerfOn: sleuthPerfOn,
          rssAlertOn: rssAlertOn,
        )) {
          continue;
        }
        final alertAt = a['at']?.toString();
        events.add({
          'id': 'ev_${idx++}',
          'type': 'alert',
          'at': (alertAt != null && alertAt.isNotEmpty)
              ? alertAt
              : (s['at']?.toString() ?? ''),
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
            if (raw['type'] != null &&
                raw['type'].toString() != alertType)
              'legacyType': raw['type'],
          },
        });
      }
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
  for (final raw in alerts) {
    for (final a in expandBagAlerts(raw, expandSleuthBags: sleuthPerfOn)) {
      final alertType = _normalizeAlertType(a['type']?.toString());
      if (_shouldHideAlert(
        alertType,
        sleuthPerfOn: sleuthPerfOn,
        rssAlertOn: rssAlertOn,
      )) {
        continue;
      }
      final key = '$alertType|${a['stepId']}|${a['message']}';
      if (seenAlertKeys.contains(key)) continue;
      seenAlertKeys.add(key);
      final sid = a['stepId']?.toString();
      final stepRoute = sid != null && stepById.containsKey(sid)
          ? _stepRoute(stepById[sid]!)
          : null;
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
          if (raw['type'] != null && raw['type'].toString() != alertType)
            'legacyType': raw['type'],
        },
      });
    }
  }

  // Drop empty WeakRef "leaks" that only echo Sleuth heap_growing.
  _dropEchoMemoryLeaks(events);
  // Same detector polled across steps / bags → one card (worse magnitude).
  _dedupeAlertsByTypeAndStep(events);

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

  final alertEventCount =
      events.where((e) => e['type']?.toString() == 'alert').length;

  return {
    'events': events,
    'timeline': timeline,
    'stats': {
      'eventCount': events.length,
      'alertCount': alertEventCount,
      'segmentCount': timeline.length,
      ...netStats,
      ...perf,
    },
  };
}

bool _thresholdFlag(
  Map<String, dynamic> thresholds,
  String key, {
  required bool defaultWhenMissing,
}) {
  if (!thresholds.containsKey(key)) return defaultWhenMissing;
  return thresholds[key] == true;
}

/// Sleuth / RSS performance alerts gated by report thresholds.
bool _shouldHideAlert(
  String alertType, {
  required bool sleuthPerfOn,
  required bool rssAlertOn,
}) {
  if (!rssAlertOn && alertType == 'memory_increase') return true;
  if (sleuthPerfOn) return false;
  if (alertType == 'sleuth_detector' ||
      alertType == 'sleuth_issues' ||
      alertType == 'jank' ||
      alertType == 'slow_frame' ||
      alertType == 'sleuth_issue') {
    return true;
  }
  if (_sessionSnapshotAlertFamilies.contains(alertType)) return true;
  for (final f in _sessionSnapshotAlertFamilies) {
    if (alertType.startsWith('$f:')) return true;
  }
  // structural instance ids / network sleuth families
  const prefixes = <String>[
    'excessive_keep_alive',
    'high_frequency_same_path',
    'slow_request',
    'large_response',
    'request_frequency',
    'http_error_spike',
  ];
  for (final p in prefixes) {
    if (alertType == p || alertType.startsWith('$p:')) return true;
  }
  return false;
}

/// `sleuth_detector` / `sleuth_issues` bags → one first-class alert per issue.
///
/// Design: timeline shows `sustained_jank` / `gc_pressure` / … as events,
/// not a single bag with nested bullets (see report-timeline-v4).
/// When [expandSleuthBags] is false, bags are dropped (not shown as a lump).
List<Map<String, dynamic>> expandBagAlerts(
  Map<String, dynamic> raw, {
  bool expandSleuthBags = true,
}) {
  final type = (raw['type'] ?? '').toString();
  if (type != 'sleuth_detector' && type != 'sleuth_issues') {
    return [Map<String, dynamic>.from(raw)];
  }
  if (!expandSleuthBags) return const [];
  final value = raw['value'];
  if (value is! List || value.isEmpty) {
    return [Map<String, dynamic>.from(raw)];
  }
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final item in value) {
    final expanded = _issueEntryToAlert(raw, item);
    if (expanded == null) continue;
    final id = expanded['type']?.toString() ?? '';
    final msg = expanded['message']?.toString() ?? '';
    final key = '$id|$msg';
    if (!seen.add(key)) continue;
    out.add(expanded);
  }
  return out.isEmpty ? [Map<String, dynamic>.from(raw)] : out;
}

Map<String, dynamic>? _issueEntryToAlert(
  Map<String, dynamic> parent,
  Object? item,
) {
  if (item is Map) {
    final m = Map<String, dynamic>.from(item);
    final alertType = _issueAlertType(m);
    if (alertType == null || alertType == 'jank_detected') return null;
    final title = (m['title'] ?? m['detail'] ?? m['message'] ?? alertType)
        .toString();
    return <String, dynamic>{
      'type': alertType,
      'stepId': parent['stepId'],
      'action': parent['action'],
      'message': title,
      if (parent['at'] != null) 'at': parent['at'],
      'value': <String, dynamic>{
        ...m,
        'stableId': m['stableId'] ?? m['id'] ?? alertType,
        'source': m['source'] ?? 'sleuth_expand',
      },
    };
  }
  if (item is String) {
    final s = item.trim();
    if (s.isEmpty) return null;
    final alertType = _alertTypeFromIssueText(s) ?? 'sleuth_issue';
    if (alertType == 'jank_detected') return null;
    final title = _titleFromIssueText(s) ?? s;
    return <String, dynamic>{
      'type': alertType,
      'stepId': parent['stepId'],
      'action': parent['action'],
      'message': title,
      if (parent['at'] != null) 'at': parent['at'],
      'value': <String, dynamic>{
        'title': title,
        'stableId': alertType,
        'source': 'sleuth_expand',
        'raw': s.length > 240 ? '${s.substring(0, 240)}…' : s,
      },
    };
  }
  return null;
}

String? _issueAlertType(Map<String, dynamic> m) {
  final id = (m['stableId'] ?? m['id'] ?? '').toString().trim();
  if (id.isNotEmpty) {
    if (id == 'jank_detected') return 'jank_detected';
    // Instance-scoped keep full id; family suffix after '.' → family.
    if (id.contains(':')) return id;
    final dot = id.indexOf('.');
    if (dot > 0) return id.substring(0, dot);
    return id;
  }
  final title = (m['title'] ?? m['detail'] ?? m['message'] ?? '').toString();
  return _alertTypeFromIssueText(title);
}

String? _alertTypeFromIssueText(String text) {
  final t = text.toLowerCase();
  const patterns = <String, String>{
    'sustained jank': 'sustained_jank',
    'raster dominance': 'raster_dominance',
    'gc pressure': 'gc_pressure',
    'heap growing': 'heap_growing',
    'heap near': 'heap_near_capacity',
    'native memory': 'native_memory_growing',
    'shader': 'shader_compilation',
    'heavy computation': 'heavy_compute',
    'heavy compute': 'heavy_compute',
    'platform channel': 'platform_channel_traffic',
    'stream resource': 'stream_resource_growth',
    'rebuild': 'rebuild_activity',
    'excessive repaint': 'excessive_repaint',
    'missing repaint': 'missing_repaint_boundary',
    'layout bottleneck': 'layout_bottleneck',
    'non-lazy': 'non_lazy_list',
    'non lazy': 'non_lazy_list',
    'setstate': 'setstate_scope',
    'slow request': 'slow_request',
    'large response': 'large_response',
    'tooltip': 'tooltip_usage',
  };
  for (final e in patterns.entries) {
    if (t.contains(e.key)) return e.value;
  }
  return null;
}

String? _titleFromIssueText(String raw) {
  // PerformanceIssue(..., "Title here", route: ...)
  final m = RegExp(r'"([^"]{3,120})"').firstMatch(raw);
  return m?.group(1);
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

/// Short timeline label — prefer human title; avoid `type:IssueSeverity.x` noise.
String _alertLabel(Map<String, dynamic> a) {
  final type = _normalizeAlertType(a['type']?.toString());
  final value = a['value'];
  if (value is Map) {
    final title = value['title']?.toString().trim();
    if (title != null && title.isNotEmpty) {
      return title.length > 90 ? '${title.substring(0, 90)}…' : title;
    }
  }
  switch (type) {
    case 'jank':
    case 'slow_frame':
      if (value is Map) {
        final ms = value['frameMs'];
        final phase = value['suspectedPhase']?.toString();
        final msStr = ms is num ? ms.toStringAsFixed(0) : '?';
        if (phase != null && phase.isNotEmpty && phase != 'unknown') {
          return '$type · ${msStr}ms · $phase';
        }
        return '$type · ${msStr}ms';
      }
      if (type == 'slow_frame' && value is num) {
        return 'slow_frame · ${value.toStringAsFixed(0)}ms';
      }
      return value != null ? '$type · +$value' : type;
    case 'crash':
      if (value is Map) {
        final err = value['error']?.toString() ?? '';
        if (err.isNotEmpty) {
          return err.length > 72 ? '${err.substring(0, 72)}…' : err;
        }
        final kind = value['kind']?.toString();
        if (kind != null && kind.isNotEmpty) return kind;
      }
      final msg = a['message']?.toString();
      if (msg != null && msg.isNotEmpty) {
        // Strip "FlutterError：" / "未捕获异常：" prefixes for the timeline label.
        final cleaned = msg
            .replaceFirst(RegExp(r'^(FlutterError|未捕获异常)[：:]'), '')
            .trim();
        if (cleaned.isNotEmpty) {
          return cleaned.length > 72 ? '${cleaned.substring(0, 72)}…' : cleaned;
        }
      }
      return 'crash';
    case 'memory_increase':
    case 'memory_retain_rss':
      if (value is num) {
        return '$type · +${value.toStringAsFixed(1)}MB';
      }
      return type;
    case 'slow_cold_start':
      if (value is num) {
        return 'slow_cold_start · ${value.toStringAsFixed(0)}ms';
      }
      return type;
    case 'memory_leak':
      final msg = a['message']?.toString();
      if (msg != null && msg.isNotEmpty) {
        // "pop /login 后 Sleuth: Heap Growing: … · evidence=sleuth"
        final cut = msg.split(' · evidence').first.trim();
        return cut.length > 90 ? '${cut.substring(0, 90)}…' : cut;
      }
      return 'memory_leak';
    default:
      final msg = a['message']?.toString();
      if (msg != null && msg.isNotEmpty && msg.length <= 90) return msg;
      return type;
  }
}

/// Sleuth "current inventory" detectors — one card per session (keep worst).
/// Per-step / per-hit types (jank frame, leak) stay keyed by step.
/// Crash kinds (flutter_error / zone / uncaught) must not collapse together.
const _sessionSnapshotAlertFamilies = <String>{
  'sustained_jank',
  'raster_dominance',
  'gc_pressure',
  'heap_growing',
  'heap_near_capacity',
  'native_memory_growing',
  'shader_compilation',
  'heavy_compute',
  'platform_channel_traffic',
  'stream_resource_growth',
  'rebuild_activity',
  'excessive_repaint',
  'missing_repaint_boundary',
  'excessive_repaint_boundary',
  'layout_bottleneck',
  'wrap_layout_bottleneck',
  'non_lazy_list',
  'non_lazy_shrinkwrap',
  'setstate_scope',
  'tooltip_usage',
};

/// `memory_leak` with evidence=sleuth, alive=0 — already covered by heap_growing.
void _dropEchoMemoryLeaks(List<Map<String, dynamic>> events) {
  var hasHeapGrowing = false;
  for (final e in events) {
    if (e['type']?.toString() != 'alert') continue;
    final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? const {};
    final t = _normalizeAlertType(
      d['alertType']?.toString() ?? d['type']?.toString(),
    );
    if (t == 'heap_growing' || t.startsWith('heap_growing')) {
      hasHeapGrowing = true;
      break;
    }
  }
  if (!hasHeapGrowing) return;
  events.removeWhere((e) {
    if (e['type']?.toString() != 'alert') return false;
    final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? const {};
    final t = _normalizeAlertType(
      d['alertType']?.toString() ?? d['type']?.toString(),
    );
    if (t != 'memory_leak') return false;
    final v = d['value'];
    if (v is! Map) return false;
    if (v['evidence']?.toString() != 'sleuth') return false;
    final alive = v['alive'];
    final count = v['aliveCount'];
    final emptyList = alive is List && alive.isEmpty;
    final zero = count == 0 || count == null;
    return emptyList || zero;
  });
}

String _crashKindOfDetail(Map<String, dynamic> d) {
  final v = d['value'];
  if (v is Map && v['kind'] != null) return v['kind'].toString();
  final msg = d['message']?.toString() ?? '';
  final m = RegExp(r'crash kind=([a-z_]+)').firstMatch(msg);
  return m?.group(1) ?? '';
}

/// Collapse duplicate detector cards (bag snapshots / multi-step polls).
void _dedupeAlertsByTypeAndStep(List<Map<String, dynamic>> events) {
  final bestIndex = <String, int>{};
  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    if (e['type']?.toString() != 'alert') continue;
    final d = (e['detail'] as Map?)?.cast<String, dynamic>() ?? const {};
    final alertType = _normalizeAlertType(
      d['alertType']?.toString() ?? d['type']?.toString(),
    );
    final family =
        alertType.contains(':') ? alertType.split(':').first : alertType;
    final sid = e['stepId']?.toString() ?? d['stepId']?.toString() ?? '';
    // Same route step can host all three D1 crash kinds — key by kind.
    final crashKind = family == 'crash' ? _crashKindOfDetail(d) : '';
    final key = _sessionSnapshotAlertFamilies.contains(family)
        ? family
        : (family == 'crash'
            ? 'crash|$sid|$crashKind'
            : '$alertType|$sid');
    final prev = bestIndex[key];
    if (prev == null) {
      bestIndex[key] = i;
      continue;
    }
    if (_alertEventBetter(e, events[prev])) {
      events[prev] = e;
    }
    events[i] = <String, dynamic>{'type': '_drop'};
  }
  events.removeWhere((e) => e['type']?.toString() == '_drop');
}

bool _alertEventBetter(Map<String, dynamic> a, Map<String, dynamic> b) {
  final da = (a['detail'] as Map?)?.cast<String, dynamic>() ?? const {};
  final db = (b['detail'] as Map?)?.cast<String, dynamic>() ?? const {};
  final va = da['value'];
  final vb = db['value'];
  final sa = _severityRankOf(
    va is Map ? va['severity']?.toString() : null,
  );
  final sb = _severityRankOf(
    vb is Map ? vb['severity']?.toString() : null,
  );
  if (sa != sb) return sa > sb;
  final ma = _alertMagnitude(da);
  final mb = _alertMagnitude(db);
  if (ma != mb) return ma > mb;
  final ta = DateTime.tryParse(a['at']?.toString() ?? '');
  final tb = DateTime.tryParse(b['at']?.toString() ?? '');
  if (ta != null && tb != null && ta != tb) return ta.isAfter(tb);
  final la = (va is Map ? va['title']?.toString() : null) ??
      da['message']?.toString() ??
      '';
  final lb = (vb is Map ? vb['title']?.toString() : null) ??
      db['message']?.toString() ??
      '';
  return la.length >= lb.length;
}

/// Prefer larger GC/min, KB/s, severe-frame counts when severity ties.
double _alertMagnitude(Map<String, dynamic> detail) {
  final value = detail['value'];
  final text = [
    if (value is Map) value['title'],
    if (value is Map) value['detail'],
    detail['message'],
  ].whereType<Object>().map((e) => e.toString()).join(' ');
  final gc = RegExp(r'(\d+(?:\.\d+)?)\s*GC/min', caseSensitive: false)
      .firstMatch(text);
  if (gc != null) return double.tryParse(gc.group(1)!) ?? 0;
  final kb = RegExp(r'\+?(\d+(?:\.\d+)?)\s*KB/s', caseSensitive: false)
      .firstMatch(text);
  if (kb != null) return double.tryParse(kb.group(1)!) ?? 0;
  final frames =
      RegExp(r'(\d+)\s+severe frames', caseSensitive: false).firstMatch(text);
  if (frames != null) return double.tryParse(frames.group(1)!) ?? 0;
  return text.length.toDouble();
}

int _severityRankOf(String? sev) {
  final s = (sev ?? '').toLowerCase();
  if (s.contains('critical') || s.contains('error')) return 3;
  if (s.contains('warning')) return 2;
  if (s.contains('info')) return 1;
  return 0;
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
          lastTransition['stepId']?.toString() == sid) {
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

  void applyCover(Map<String, dynamic> seg, Map<String, dynamic> e) {
    final uri = e['screenshotDataUri']?.toString();
    final path = e['screenshotPath']?.toString();
    if ((uri == null || uri.isEmpty) && (path == null || path.isEmpty)) {
      return;
    }
    // Later shots win (post-action / land cover).
    if (uri != null && uri.isNotEmpty) seg['coverDataUri'] = uri;
    if (path != null && path.isNotEmpty) seg['coverPath'] = path;
  }

  for (final e in events) {
    final type = e['type']?.toString() ?? 'action';

    // Screenshots become page covers, not narrative rows.
    if (type == 'screenshot') {
      final route = e['route']?.toString();
      final pageKey =
          (route != null && route.isNotEmpty) ? route : '(unknown)';
      if (openPage == null || openPage!['route'] != pageKey) {
        flushPage();
        openPage = newPage(pageKey, e);
      }
      applyCover(openPage!, e);
      continue;
    }

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
  // D0 realtime frame alerts carry their own wall-clock `at`.
  final own = a['at']?.toString();
  if (own != null && own.isNotEmpty) return own;
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
