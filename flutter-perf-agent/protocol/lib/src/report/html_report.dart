import 'dart:convert';
import 'dart:io';

import 'cold_start_phases.dart';
import 'report_view.dart';

/// Build a self-contained HTML report from a report JSON map.
///
/// Layout: summary → **timeline of module segments** (events nested inside) → env.
String buildHtmlReport(Map<String, dynamic> report) {
  final view = (report['view'] as Map?)?.cast<String, dynamic>() ??
      buildReportView(report);
  // Prefer segmented timeline; fall back if old view only had flat events.
  var timeline =
      (view['timeline'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final looksFlat = timeline.isNotEmpty &&
      timeline.first['module'] == null &&
      timeline.first['type'] != null;
  if (looksFlat || timeline.isEmpty) {
    // Re-derive so modules sit inside the timeline.
    final rebuilt = buildReportView(report);
    timeline =
        (rebuilt['timeline'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  }
  final stats = (view['stats'] as Map?)?.cast<String, dynamic>() ??
      (buildReportView(report)['stats'] as Map?)?.cast<String, dynamic>() ??
      const {};

  final testName = _esc(report['testName']?.toString() ?? 'unnamed');
  final sessionId = _esc(report['sessionId']?.toString() ?? '');
  final mode = _esc(report['mode']?.toString() ?? '-');
  final startedAt = _esc(_fmtTime(report['startedAt']?.toString()));
  final endedAt = _esc(_fmtTime(report['endedAt']?.toString()));
  final durationMs = report['durationMs'] ?? '-';
  final summary = (report['summary'] as Map?)?.cast<String, dynamic>() ?? {};
  final thresholds =
      (report['thresholds'] as Map?)?.cast<String, dynamic>() ?? {};
  final note = _esc(report['note']?.toString() ?? '');
  final sleuthMd = report['sleuthSummaryMarkdown']?.toString();
  final sleuthDiag =
      (report['sleuthDiagnose'] as Map?)?.cast<String, dynamic>();
  final reportOwner = _esc(report['reportOwner']?.toString() ?? '-');
  final schemaVersion = report['schemaVersion'] ?? '-';
  final steps =
      (report['steps'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

  return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Perf Report · $testName</title>
<style>
${_css()}
</style>
</head>
<body>
<main>
  <h1>$testName</h1>
  <p class="sub">session $sessionId · $mode · owner $reportOwner · schema $schemaVersion<br/>
  $startedAt → $endedAt</p>

  <div class="grid">
    <div class="stat"><label>总耗时</label><b>$durationMs ms</b></div>
    <div class="stat"><label>步骤</label><b>${summary['stepCount'] ?? steps.length}</b></div>
    <div class="stat"><label>成功</label><b>${summary['okSteps'] ?? '-'}</b></div>
    <div class="stat"><label>告警</label><b>${summary['alertCount'] ?? 0}</b></div>
    <div class="stat"><label>网络</label><b>${summary['networkRequestCount'] ?? stats['networkCount'] ?? '-'}</b></div>
    <div class="stat"><label>模块段</label><b>${timeline.length}</b></div>
    <div class="stat"><label>avg FPS</label><b>${_num(stats['avgFps'])}</b></div>
    <div class="stat"><label>RSS 峰值</label><b>${_num(stats['rssPeakMb'])} MB</b></div>
  </div>

  <h2 id="timeline">全会话时间线</h2>
  <p class="muted">时间线内嵌模块（启动 / 页面 / 转场 / 告警）；模块内是该段事件。筛选按模块类型。</p>
  <div class="filters" id="tl-filters">
    <button type="button" class="chip active" data-filter="all">全部</button>
    <button type="button" class="chip" data-filter="startup">启动</button>
    <button type="button" class="chip" data-filter="page">页面</button>
    <button type="button" class="chip" data-filter="transition">转场</button>
    <button type="button" class="chip" data-filter="alert">告警</button>
  </div>
  ${_segmentedTimelineHtml(timeline)}

  <h2>环境与阈值</h2>
  <div class="grid">
    <div class="stat"><label>maxFrameCostMs</label><b>${thresholds['maxFrameCostMs'] ?? '-'}</b></div>
    <div class="stat"><label>memoryIncreaseWarningMB</label><b>${thresholds['memoryIncreaseWarningMB'] ?? '-'}</b></div>
    <div class="stat"><label>slowRequestMs</label><b>${thresholds['slowRequestMs'] ?? '-'}</b></div>
    <div class="stat"><label>ttffWarningMs</label><b>${thresholds['ttffWarningMs'] ?? '-'}</b></div>
    <div class="stat"><label>transitionSettleMs</label><b>${thresholds['transitionSettleMs'] ?? '-'}</b></div>
    <div class="stat"><label>leakConfirmRounds</label><b>${thresholds['leakConfirmRounds'] ?? '-'}</b></div>
    <div class="stat"><label>vmConnected</label><b>${sleuthDiag?['vmConnected'] ?? '-'}</b></div>
    <div class="stat"><label>captureMode</label><b>${sleuthDiag?['captureMode'] ?? '-'}</b></div>
  </div>
  ${sleuthDiag?['advisory'] != null ? '<p class="muted">${_esc(sleuthDiag!['advisory']?.toString())}</p>' : ''}
  ${sleuthMd != null && sleuthMd.isNotEmpty ? '<details><summary>Sleuth summary</summary><pre>${_esc(sleuthMd)}</pre></details>' : ''}

  <footer>$note</footer>
</main>
<script>
${_filterScript()}
</script>
</body>
</html>''';
}

String _css() => r'''
  :root {
    --bg: #f4f7f5;
    --card: #ffffff;
    --ink: #14231b;
    --muted: #5b6b62;
    --line: #d7e2db;
    --good: #0b6e4f;
    --bad: #b42318;
    --warn-bg: #fff1f0;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; font-family: "IBM Plex Sans", "PingFang SC", sans-serif;
    background: linear-gradient(180deg, #e8f2ec 0%, var(--bg) 240px);
    color: var(--ink); line-height: 1.5;
  }
  main { max-width: 960px; margin: 0 auto; padding: 32px 20px 64px; }
  h1 { font-size: 1.75rem; margin: 0 0 8px; letter-spacing: -0.02em; }
  h2 { margin: 36px 0 12px; font-size: 1.15rem; scroll-margin-top: 16px; }
  h3 { margin: 0; font-size: 1rem; }
  .sub { color: var(--muted); margin: 0 0 24px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit,minmax(120px,1fr)); gap: 12px; }
  .stat {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px;
  }
  .stat label { display:block; color: var(--muted); font-size: 12px; }
  .stat b { font-size: 1.25rem; }
  .metrics { display:grid; grid-template-columns: repeat(auto-fit,minmax(100px,1fr)); gap: 10px; margin: 10px 0; }
  .metrics label { display:block; color: var(--muted); font-size: 12px; }
  .muted { color: var(--muted); font-size: 13px; }
  .badge { display:inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; font-weight: 600; }
  .badge.good { background: #e3f5ee; color: var(--good); }
  .badge.bad { background: #fdecec; color: var(--bad); }
  .badge.net { background: #e8eef8; color: #1e4a8c; }
  .badge.mod-startup { background: #fff4e5; color: #9a5b00; }
  .badge.mod-page { background: #e3f5ee; color: var(--good); }
  .badge.mod-transition { background: #e8eef8; color: #1e4a8c; }
  .badge.mod-alert { background: #fdecec; color: var(--bad); }
  .filters { display:flex; flex-wrap:wrap; gap: 8px; margin: 0 0 14px; }
  .chip {
    border: 1px solid var(--line); background: #fff; color: var(--ink);
    border-radius: 999px; padding: 4px 12px; font-size: 13px; cursor: pointer;
  }
  .chip.active { background: #14231b; color: #fff; border-color: #14231b; }
  .seg-timeline { margin: 0; padding: 0; list-style: none; }
  .seg-timeline > li {
    position: relative; padding: 0 0 20px 22px;
    border-left: 2px solid var(--line);
  }
  .seg-timeline > li:last-child { padding-bottom: 0; }
  .seg-timeline > li::before {
    content: ""; position: absolute; left: -6px; top: 14px;
    width: 10px; height: 10px; border-radius: 50%;
    background: var(--good); border: 2px solid #fff;
  }
  .seg-timeline > li.startup::before { background: #c45c26; }
  .seg-timeline > li.transition::before { background: #1e4a8c; }
  .seg-timeline > li.alert::before { background: var(--bad); }
  .seg-timeline > li.hidden { display: none; }
  .seg {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    padding: 14px 16px;
  }
  .seg-head { display:flex; justify-content:space-between; gap:12px; flex-wrap:wrap; align-items:flex-start; }
  .seg-meta { font-size: 12px; color: var(--muted); margin-top: 4px; }
  .shot { margin: 12px 0; }
  .shot img {
    max-width: min(100%, 420px); border-radius: 8px; border: 1px solid var(--line);
    background: #0f1a14;
  }
  .inner-timeline { margin: 12px 0 0; padding: 0; list-style: none; }
  .inner-timeline li {
    position: relative; padding: 0 0 12px 16px;
    border-left: 2px solid #e8eef0;
  }
  .inner-timeline li:last-child { padding-bottom: 0; }
  .inner-timeline li::before {
    content: ""; position: absolute; left: -4px; top: 6px;
    width: 6px; height: 6px; border-radius: 50%; background: #8aa396;
  }
  .inner-timeline li.fail::before, .inner-timeline li.alert::before { background: var(--bad); }
  .inner-timeline li.network::before { background: #6b5b95; }
  .inner-timeline li.navigate::before { background: #1e4a8c; }
  .inner-timeline .ev-type {
    font-size: 11px; font-weight: 700; letter-spacing: 0.04em;
    text-transform: uppercase; color: var(--muted);
  }
  .inner-timeline .ev-label { font-weight: 600; margin: 2px 0; }
  .inner-timeline .ev-meta { font-size: 12px; color: var(--muted); }
  .net-card { margin-top: 8px; border: 1px solid var(--line); border-radius: 8px; padding: 8px 12px; background: #fafcfb; }
  .net-card summary { cursor: pointer; font-size: 13px; }
  .net-url { word-break: break-all; font-size: 12px; color: var(--muted); }
  .net-grid { display:grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 8px; }
  @media (max-width: 720px) { .net-grid { grid-template-columns: 1fr; } }
  .net-grid h4 { margin: 8px 0 4px; font-size: 12px; color: var(--muted); font-weight: 600; }
  .net-grid pre, pre {
    margin: 0; max-height: 280px; overflow: auto;
    background:#0f1a14; color:#d7ece1; padding:10px; border-radius:6px;
    font-size: 11px; line-height: 1.35; white-space: pre-wrap; word-break: break-word;
  }
  details { margin-top: 8px; }
  footer { margin-top: 28px; color: var(--muted); font-size: 13px; }
  .phases { margin: 14px 0; }
  .phases h4 { margin: 0 0 8px; font-size: 0.95rem; }
  .phases table, .data-table { width: 100%; border-collapse: collapse; font-size: 13px; }
  .phases th, .phases td, .data-table th, .data-table td {
    text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line);
  }
  .phases th, .data-table th { color: var(--muted); font-weight: 600; font-size: 12px; }
  .phases tr.highlight td { background: #f0faf5; }
  .phases tr.total td { font-weight: 700; }
  .phases .bar-wrap {
    height: 10px; background: #e8eef0; border-radius: 999px; overflow: hidden; min-width: 80px;
  }
  .phases .bar { height: 100%; background: var(--good); border-radius: 999px; }
  .phases .bar.hi { background: #c45c26; }
  .phases .bar.engine { background: #1e4a8c; }
  .phases .bar.post { background: #6b5b95; }
  .phases .note { color: var(--muted); font-size: 12px; }
  .alert-inline {
    background: var(--warn-bg); border: 1px solid #f3b4ae; border-radius: 8px;
    padding: 8px 10px; margin-top: 6px; display:grid; gap: 4px;
  }
  .alert-inline ul.alert-values {
    margin: 4px 0 0; padding-left: 1.2em; font-size: 12px; color: var(--text);
  }
  .alert-inline ul.alert-values li { margin: 2px 0; }
  .alert-inline .alert-metric { font-size: 12px; color: var(--muted); }
''';

String _filterScript() => r'''
(function () {
  var root = document.getElementById('tl-filters');
  if (!root) return;
  var items = document.querySelectorAll('#global-timeline > li');
  root.addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-filter]');
    if (!btn) return;
    var filter = btn.getAttribute('data-filter');
    root.querySelectorAll('.chip').forEach(function (c) { c.classList.remove('active'); });
    btn.classList.add('active');
    items.forEach(function (li) {
      var m = li.getAttribute('data-module') || '';
      var show = filter === 'all' || m === filter;
      li.classList.toggle('hidden', !show);
    });
  });
})();
''';

String _segmentedTimelineHtml(List<Map<String, dynamic>> segments) {
  if (segments.isEmpty) {
    return '<p class="muted">无时间线模块</p>';
  }
  final items = <String>[];
  var i = 0;
  for (final seg in segments) {
    i++;
    final id = seg['id']?.toString() ?? 'seg_$i';
    final module = seg['module']?.toString() ?? 'page';
    items.add('''
<li id="$id" class="$module" data-module="${_esc(module)}">
  ${_segmentCardHtml(seg, index: i)}
</li>''');
  }
  return '<ol class="seg-timeline" id="global-timeline">${items.join('\n')}</ol>';
}

String _segmentCardHtml(Map<String, dynamic> seg, {required int index}) {
  final module = seg['module']?.toString() ?? 'page';
  final title = _esc(seg['title']?.toString() ?? module);
  final at = _esc(_fmtTime(seg['at']?.toString()));
  final modLabel = switch (module) {
    'startup' => 'App 启动',
    'transition' => '转场',
    'alert' => '告警',
    _ => '页面',
  };
  final badges = StringBuffer()
    ..write('<span class="badge mod-$module">$modLabel</span> ');
  if (module == 'page') {
    badges
      ..write('<span class="badge net">${seg['eventCount'] ?? 0} 事件</span> ')
      ..write('<span class="badge net">${seg['networkCount'] ?? 0} 请求</span>');
    if ((seg['alertCount'] as num?) != null && (seg['alertCount'] as num) > 0) {
      badges.write(
        ' <span class="badge bad">${seg['alertCount']} 告警</span>',
      );
    }
  }
  if (module == 'transition') {
    badges.write(
      '<span class="badge net">${_esc(seg['transitionKind']?.toString() ?? 'unknown')}</span>',
    );
  }

  final headerExtra = switch (module) {
    'startup' => '''
  <div class="metrics">
    <div><label>TTFF</label><b>${_num(seg['ttffMs'])} ms</b></div>
    <div><label>TTI</label><b>${_num(seg['ttiMs'])} ms</b></div>
    <div><label>Engine TTFF</label><b>${_num(seg['engineTtffMs'])} ms</b></div>
  </div>
  ${_coldStartPhasesHtml(seg)}
  ${_shotFromFields(seg['screenshotDataUri'] as String?, seg['screenshotPath'] as String?)}''',
    'page' => _pageDiffsHtml(seg),
    'transition' => _transitionExtrasHtml(seg),
    _ => '',
  };

  final events =
      (seg['events'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  // Startup already shows phases + cover; still list nested events if more than cold_start alone.
  final showInner = module != 'startup' || events.length > 1;

  return '''
<article class="seg">
  <div class="seg-head">
    <div>
      <h3>$index · $title</h3>
      <div class="seg-meta">$at</div>
    </div>
    <div>$badges</div>
  </div>
  $headerExtra
  ${showInner ? _innerEventsHtml(events) : ''}
</article>''';
}

String _transitionExtrasHtml(Map<String, dynamic> seg) {
  final kind = _esc(seg['transitionKind']?.toString() ?? 'unknown');
  final from = _esc(seg['from']?.toString());
  final to = _esc(seg['to']?.toString());
  final leak = (seg['leak'] as Map?)?.cast<String, dynamic>();
  final buf = StringBuffer()
    ..writeln('<p class="seg-meta">$from → $to · <code>$kind</code></p>');
  if (leak == null) return buf.toString();
  final alive = (leak['alive'] as List?) ?? const [];
  final aliveCount = leak['aliveCount'] ?? alive.length;
  final rssDelta = leak['rssDeltaMb'];
  final evidence = leak['evidence']?.toString() ?? 'weak_ref';
  final sleuthHits = (leak['sleuthHits'] as List?) ?? const [];
  if (aliveCount is num && aliveCount > 0) {
    final names = alive
        .map((e) => e is Map ? e['name']?.toString() ?? '?' : e.toString())
        .join(', ');
    buf.writeln(
      '<p class="badge bad">泄漏 WeakRef ×$aliveCount：${_esc(names)}'
      ' · <code>${_esc(evidence)}</code></p>',
    );
  } else if (sleuthHits.isEmpty) {
    buf.writeln('<p class="muted">WeakRef 探针：无仍可达对象</p>');
  }
  if (sleuthHits.isNotEmpty) {
    final titles = sleuthHits
        .map((e) => e is Map
            ? (e['title'] ?? e['stableId'] ?? '?').toString()
            : e.toString())
        .join(', ');
    buf.writeln(
      '<p class="badge bad">Sleuth 转场窗新增：${_esc(titles)}'
      ' · <code>${_esc(evidence)}</code></p>',
    );
  }
  final counts = (leak['aliveCounts'] as List?) ?? const [];
  if (counts.length >= 2) {
    final series = counts.map((e) => e.toString()).join('→');
    final multi = leak['multiRoundConfirmed'] == true;
    final round = leak['roundIndex'];
    buf.writeln(
      multi
          ? '<p class="badge bad">多轮确认：同路由 ${counts.length} 次进出 '
              '存活数 [$series]（round $round）</p>'
          : '<p class="muted">多轮：同路由 ${counts.length} 次进出 '
              '存活数 [$series]（round $round）</p>',
    );
  }
  if (rssDelta != null) {
    buf.writeln(
      '<p class="muted">RSS 辅证 Δ ${_num(rssDelta)} MB（settle ${leak['settleMs'] ?? '-'}ms）</p>',
    );
  }
  return buf.toString();
}

String _pageDiffsHtml(Map<String, dynamic> seg) {
  final diffs =
      (seg['diffs'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  if (diffs.isEmpty) return '';
  final rows = diffs.map((d) {
    return '<tr>'
        '<td>${_esc(d['stepId']?.toString())}</td>'
        '<td>${_esc(d['cause']?.toString())}</td>'
        '<td>${_esc(d['durationMs']?.toString() ?? '-')} ms</td>'
        '<td>${_num(d['memoryDeltaMb'])}</td>'
        '<td>${d['jankDelta'] ?? '-'}</td>'
        '</tr>';
  }).join('\n');
  return '''
<table class="data-table" style="margin-top:10px;">
  <thead><tr><th>步骤</th><th>操作</th><th>耗时</th><th>Δmem</th><th>Jank</th></tr></thead>
  <tbody>$rows</tbody>
</table>''';
}

String _innerEventsHtml(List<Map<String, dynamic>> events) {
  if (events.isEmpty) return '<p class="muted">无事件</p>';
  final items = <String>[];
  var i = 0;
  for (final t in events) {
    i++;
    final id = t['id']?.toString() ?? 'ev_$i';
    final type = t['type']?.toString() ?? 'action';
    final label = t['label']?.toString() ?? type;
    final ok = t['ok'] != false;
    final at = _fmtTime(t['at']?.toString());
    final detail =
        (t['detail'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final cls = [
      type,
      if (!ok || type == 'alert') 'fail',
    ].join(' ');
    final meta = <String>[];
    if (at.isNotEmpty) meta.add(at);
    if (t['stepId'] != null) meta.add(t['stepId'].toString());
    if (t['source'] != null) meta.add(t['source'].toString());
    if (type == 'network') {
      if (detail['statusCode'] != null) meta.add('HTTP ${detail['statusCode']}');
      if (detail['durationMs'] != null) meta.add('${detail['durationMs']}ms');
    }
    if (type == 'navigate') {
      meta.add('${detail['from'] ?? '?'} → ${detail['to'] ?? '?'}');
      if (detail['transitionKind'] != null) {
        meta.add(detail['transitionKind'].toString());
      }
    }
    final shot = type == 'screenshot' || type == 'cold_start'
        ? _shotFromFields(
            t['screenshotDataUri'] as String?,
            t['screenshotPath'] as String?,
          )
        : '';
    final netExpand = type == 'network' ? _networkExpandHtml(detail) : '';
    final alertBox = type == 'alert'
        ? '''
<div class="alert-inline">
  <strong>${_esc(detail['type']?.toString() ?? 'alert')}</strong>
  <span>${_esc(t['label']?.toString())}</span>
  ${_alertValueHtml(detail)}
</div>'''
        : '';
    items.add('''
<li id="$id" class="$cls" data-type="${_esc(type)}">
  <div class="ev-type">$i · ${_esc(type)}</div>
  <div class="ev-label">${_esc(label)}</div>
  ${meta.isEmpty ? '' : '<div class="ev-meta">${_esc(meta.join(' · '))}</div>'}
  $shot
  $netExpand
  $alertBox
</li>''');
  }
  return '<ol class="inner-timeline">${items.join('\n')}</ol>';
}

/// Expand alert `detail.value` under the message (sleuth titles, MB, leak…).
String _alertValueHtml(Map<String, dynamic> detail) {
  final value = detail['value'];
  if (value == null) return '';

  String clip(String s, [int max = 140]) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  if (value is num) {
    final th = detail['threshold'];
    final thPart = th != null ? ' · 阈值 ${_esc(th.toString())}' : '';
    return '<div class="alert-metric">value=${_esc(value.toString())}$thPart</div>';
  }

  if (value is List) {
    if (value.isEmpty) return '';
    final items = <String>[];
    for (final e in value.take(8)) {
      if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        final title = m['title']?.toString() ??
            m['name']?.toString() ??
            m['message']?.toString() ??
            m['type']?.toString() ??
            e.toString();
        final sev = m['severity']?.toString();
        final line = sev != null && sev.isNotEmpty
            ? '${clip(title)} · $sev'
            : clip(title);
        items.add('<li>${_esc(line)}</li>');
      } else {
        items.add('<li>${_esc(clip(e.toString()))}</li>');
      }
    }
    return '<ul class="alert-values">${items.join()}</ul>';
  }

  if (value is Map) {
    final m = Map<String, dynamic>.from(value);
    final bits = <String>[];
    final evidence = m['evidence']?.toString();
    if (evidence != null && evidence.isNotEmpty) {
      bits.add('evidence=$evidence');
    }
    final alive = m['alive'];
    if (alive is List && alive.isNotEmpty) {
      final names = alive.take(5).map((e) {
        if (e is Map) return e['name']?.toString() ?? e.toString();
        return e.toString();
      }).join(', ');
      bits.add('alive: $names');
    }
    final counts = m['aliveCounts'];
    if (counts is List && counts.isNotEmpty) {
      bits.add('counts=[${counts.join('→')}]');
    }
    if (bits.isEmpty) {
      return '<div class="alert-metric">${_esc(clip(value.toString(), 200))}</div>';
    }
    return '<div class="alert-metric">${_esc(bits.join(' · '))}</div>';
  }

  return '<div class="alert-metric">${_esc(clip(value.toString()))}</div>';
}

String _prettyJsonOrMap(Object? raw) {
  if (raw == null) return '';
  try {
    if (raw is Map || raw is List) {
      return _esc(const JsonEncoder.withIndent('  ').convert(raw));
    }
    final s = raw.toString();
    if (s.isEmpty) return '';
    return _esc(s);
  } catch (_) {
    return _esc(raw.toString());
  }
}

String _coldStartPhasesHtml(Map<String, dynamic> step) {
  var phases = (step['startupPhases'] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const <Map<String, dynamic>>[];
  if (phases.isEmpty) {
    final startup = (step['startup'] as Map?)?.cast<String, dynamic>();
    phases = buildColdStartPhases(startup);
  }
  if (phases.isEmpty) {
    return '<p class="muted">暂无冷启动分阶段数据（需 Sleuth.init + 首帧）。</p>';
  }

  double? ttff = (step['ttffMs'] as num?)?.toDouble();
  if (ttff == null) {
    for (final p in phases) {
      if (p['id'] == 'ttff') {
        ttff = (p['ms'] as num?)?.toDouble();
        break;
      }
    }
  }
  final maxBar = (ttff != null && ttff > 0)
      ? ttff
      : phases
          .map((p) => (p['ms'] as num?)?.toDouble() ?? 0)
          .fold<double>(1, (a, b) => a > b ? a : b);

  final rows = phases.map((p) {
    final ms = (p['ms'] as num?)?.toDouble() ?? 0;
    final pct = (p['pctOfTtff'] as num?)?.toDouble();
    final group = p['group']?.toString() ?? '';
    final hi = p['highlight'] == true;
    final isTotal = p['isTotal'] == true;
    final barCls = [
      'bar',
      if (hi) 'hi',
      if (group == 'engine') 'engine',
      if (group == 'post') 'post',
    ].join(' ');
    final width = ((ms / maxBar) * 100).clamp(0, 100).toStringAsFixed(1);
    final pctText = pct != null ? '${pct.toStringAsFixed(1)}%' : '—';
    final rowCls = [
      if (hi) 'highlight',
      if (isTotal) 'total',
    ].join(' ');
    var name = p['name']?.toString() ?? p['id']?.toString() ?? '';
    if (p['dominantPhase'] != null) {
      name =
          '$name · 瓶颈 ${p['dominantPhase']} ${p['dominantPhasePercent'] ?? ''}%';
    }
    return '''
<tr class="$rowCls">
  <td>${_esc(name)}</td>
  <td><b>${ms.toStringAsFixed(1)}</b> ms</td>
  <td>$pctText</td>
  <td><div class="bar-wrap"><div class="$barCls" style="width:$width%"></div></div></td>
  <td class="note">${_esc(p['note']?.toString())}</td>
</tr>''';
  }).join('\n');

  return '''
<section class="phases">
  <h4>冷启动分阶段</h4>
  <table>
    <thead>
      <tr><th>阶段</th><th>耗时</th><th>占 TTFF</th><th>占比条</th><th>说明</th></tr>
    </thead>
    <tbody>$rows</tbody>
  </table>
</section>''';
}

String _networkExpandHtml(Map<String, dynamic> m) {
  final method = _esc(m['method']?.toString() ?? 'GET');
  final status = m['statusCode']?.toString() ?? '-';
  final ms = m['durationMs']?.toString() ?? '-';
  final bytes = m['responseBytes']?.toString() ?? '-';
  final url = _esc(m['url']?.toString() ?? '');
  final source = _esc(m['source']?.toString() ?? '');
  final route = m['route']?.toString();
  final err = m['error']?.toString();
  final reqHeaders = _prettyJsonOrMap(m['requestHeaders']);
  final resHeaders = _prettyJsonOrMap(m['responseHeaders']);
  final reqBody = _esc(m['requestBody']?.toString());
  final resBody = _esc(m['responseBody']?.toString());
  final reqTrunc = m['requestBodyTruncated'] == true ? ' · truncated' : '';
  final resTrunc = m['responseBodyTruncated'] == true ? ' · truncated' : '';
  final errHtml =
      err != null ? '<p class="muted">error: ${_esc(err)}</p>' : '';
  final reqH = reqHeaders.isEmpty ? '(none)' : reqHeaders;
  final resH = resHeaders.isEmpty ? '(none)' : resHeaders;
  final reqB = reqBody.isEmpty ? '(empty)' : reqBody;
  final resB = resBody.isEmpty ? '(empty)' : resBody;
  final routeHtml = route == null || route.isEmpty
      ? ''
      : '<span class="muted"> · 发起于 <code>${_esc(route)}</code></span>';
  return '''
<details class="net-card">
  <summary>
    查看请求详情 · <code>$method</code> $status · ${ms}ms · ${bytes}B
    <span class="muted">$source</span>$routeHtml<br/>
    <span class="net-url">$url</span>
  </summary>
  $errHtml
  <div class="net-grid">
    <div>
      <h4>Request Headers</h4><pre>$reqH</pre>
      <h4>Request Body$reqTrunc</h4><pre>$reqB</pre>
    </div>
    <div>
      <h4>Response Headers</h4><pre>$resH</pre>
      <h4>Response Body$resTrunc</h4><pre>$resB</pre>
    </div>
  </div>
</details>''';
}

String _shotFromFields(String? dataUri, String? path) {
  if (dataUri != null && dataUri.isNotEmpty) {
    return '<div class="shot"><img alt="screenshot" src="$dataUri"/></div>';
  }
  if (path != null && path.isNotEmpty) {
    try {
      final bytes = File(path).readAsBytesSync();
      final b64 = base64Encode(bytes);
      return '<div class="shot"><img alt="screenshot" src="data:image/png;base64,$b64"/></div>';
    } catch (_) {
      return '<p class="muted">截图不可读: ${_esc(path)}</p>';
    }
  }
  return '';
}

String _esc(String? s) {
  if (s == null) return '';
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

/// Display time as `yyyy-MM-dd HH:mm:ss.SSS` (local), keep ms for ordering.
String _fmtTime(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final t = DateTime.tryParse(raw);
  if (t == null) return raw;
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}:${two(l.second)}.'
      '${three(l.millisecond)}';
}

String _num(Object? v) {
  if (v == null) return '-';
  if (v is num) return v.toStringAsFixed(v is int ? 0 : 2);
  return v.toString();
}
