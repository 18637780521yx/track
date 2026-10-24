import 'dart:convert';

import 'cold_start_phases.dart';
import 'report_view.dart';

/// Build a self-contained HTML report from a report JSON map.
///
/// Layout: summary → **timeline of module segments** (events nested inside) → env.
String buildHtmlReport(Map<String, dynamic> report) {
  // Always re-derive view so bag alerts (sleuth_detector) expand into
  // first-class timeline events even when JSON embeds a stale `view`.
  final view = buildReportView(report);
  final timeline =
      (view['timeline'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final stats = (view['stats'] as Map?)?.cast<String, dynamic>() ?? const {};

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
  final isLive = report['live'] == true;
  final updatedAt = _esc(_fmtTime(
    report['updatedAt']?.toString() ?? report['endedAt']?.toString(),
  ));
  final liveBanner = isLive
      ? '''
  <div class="live-banner" id="live-banner">
    <span class="live-dot"></span>
    LIVE · 会话进行中 · 更新于 $updatedAt
    <span class="muted">（每 2s 自动刷新；结束会话后写带时间戳终稿）</span>
    <button type="button" class="btn-clear" id="btn-clear" title="清空当前会话账本">Clear</button>
  </div>'''
      : '''
  <div class="toolbar">
    <button type="button" class="btn-clear btn-clear-light" id="btn-clear" title="清空 App 内进行中的会话账本（需 Bridge）">Clear</button>
  </div>''';
  final liveMeta = isLive
      ? '<meta http-equiv="refresh" content="2"/>\n'
      : '';
  final liveLog = isLive ? _liveEventLogHtml(view) : '';

  return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
$liveMeta<title>Perf Report · $testName${isLive ? ' · LIVE' : ''}</title>
<style>
${_css()}
</style>
</head>
<body>
<main>
  $liveBanner
  <h1>$testName</h1>
  <p class="sub">session $sessionId · $mode · owner $reportOwner · schema $schemaVersion<br/>
  $startedAt → ${isLive ? updatedAt : endedAt}</p>
  $liveLog

  <div class="grid">
    <div class="stat"><label>总耗时</label><b>$durationMs ms</b></div>
    <div class="stat"><label>步骤</label><b>${summary['stepCount'] ?? steps.length}</b></div>
    <div class="stat"><label>成功</label><b>${summary['okSteps'] ?? '-'}</b></div>
    <div class="stat"><label>告警</label><b>${stats['alertCount'] ?? summary['alertCount'] ?? 0}</b></div>
    <div class="stat"><label>网络</label><b>${summary['networkRequestCount'] ?? stats['networkCount'] ?? '-'}</b></div>
    <div class="stat"><label>模块段</label><b>${timeline.length}</b></div>
    <div class="stat"><label>avg FPS</label><b>${_num(stats['avgFps'])}</b></div>
    <div class="stat"><label>RSS 峰值</label><b>${_num(stats['rssPeakMb'])} MB</b></div>
  </div>

  <h2 id="timeline">全会话时间线</h2>
  <p class="muted">页面级操作路径：生命周期 / 页面 / 转场。性能问题作为事件内联在对应段内（见 <code>type=alert</code>）。</p>
  <div class="filters" id="tl-filters">
    <button type="button" class="chip active" data-filter="all">全部</button>
    <button type="button" class="chip" data-filter="lifecycle">生命周期</button>
    <button type="button" class="chip" data-filter="page">页面</button>
    <button type="button" class="chip" data-filter="transition">转场</button>
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
${_clearScript()}
</script>
</body>
</html>''';
}

/// Recent flat events as a compact live log (newest last).
String _liveEventLogHtml(Map<String, dynamic> view) {
  final events =
      (view['events'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  if (events.isEmpty) {
    return '<section class="live-log"><h2>实时事件</h2>'
        '<p class="muted">尚无事件 — 操作 App 后将出现在此</p></section>';
  }
  final take = events.length > 40 ? events.sublist(events.length - 40) : events;
  final lines = <String>[];
  for (final e in take) {
    final type = e['type']?.toString() ?? '?';
    final label = e['label']?.toString() ?? '';
    final at = _fmtTime(e['at']?.toString());
    final ok = e['ok'] != false;
    final cls = (!ok || type == 'alert') ? 'log-fail' : 'log-ok';
    lines.add(
      '<div class="log-line $cls">'
      '<span class="log-at">${_esc(at)}</span> '
      '<span class="log-type">${_esc(type)}</span> '
      '${_esc(label)}'
      '</div>',
    );
  }
  return '''
<section class="live-log">
  <h2>实时事件 <span class="muted">（最近 ${take.length} 条）</span></h2>
  <div class="log-scroll">${lines.join('\n')}</div>
</section>''';
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
  .live-banner {
    display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
    background: #14231b; color: #e8f2ec; border-radius: 10px;
    padding: 10px 14px; margin: 0 0 16px; font-size: 13px; font-weight: 600;
  }
  .live-banner .muted { color: #9bb0a4; font-weight: 400; }
  .live-banner .btn-clear { margin-left: auto; }
  .toolbar { display: flex; justify-content: flex-end; margin: 0 0 12px; }
  .btn-clear {
    border: 1px solid rgba(232,242,236,.45); background: transparent;
    color: #e8f2ec; border-radius: 8px; padding: 4px 12px; font-size: 12px;
    font-weight: 600; cursor: pointer; letter-spacing: 0.02em;
  }
  .btn-clear:hover { background: rgba(232,242,236,.12); }
  .btn-clear:disabled { opacity: .5; cursor: wait; }
  .btn-clear-light {
    border-color: var(--line); color: var(--ink); background: var(--card);
  }
  .btn-clear-light:hover { background: #eef3f0; }
  .live-dot {
    width: 8px; height: 8px; border-radius: 50%; background: #3dd68c;
    box-shadow: 0 0 0 3px rgba(61,214,140,.25);
    animation: live-pulse 1.2s ease-in-out infinite;
  }
  @keyframes live-pulse {
    50% { opacity: .45; box-shadow: 0 0 0 5px rgba(61,214,140,.12); }
  }
  .live-log {
    background: var(--card); border: 1px solid var(--line);
    border-radius: 12px; padding: 12px 14px; margin: 0 0 20px;
  }
  .live-log h2 { margin: 0 0 8px; font-size: 1rem; }
  .log-scroll {
    max-height: 220px; overflow: auto; font-family: ui-monospace, Menlo, monospace;
    font-size: 12px; line-height: 1.45;
  }
  .log-line { padding: 2px 0; border-bottom: 1px solid #eef3f0; }
  .log-line.log-fail { color: var(--bad); }
  .log-at { color: var(--muted); margin-right: 6px; }
  .log-type {
    display: inline-block; min-width: 72px; font-weight: 700;
    letter-spacing: 0.02em;
  }
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
  .badge.mod-startup, .badge.mod-lifecycle { background: #fff4e5; color: #9a5b00; }
  .badge.mod-page { background: #e3f5ee; color: var(--good); }
  .badge.mod-transition { background: #e8eef8; color: #1e4a8c; }
  .badge.mod-alert { background: #fdecec; color: var(--bad); }
  .badge.src-mcp { background: #e8eef8; color: #1e4a8c; }
  .badge.src-manual { background: #f3eef8; color: #5b3d7a; }
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
  .seg-timeline > li.startup::before,
  .seg-timeline > li.lifecycle::before { background: #c45c26; }
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
  .inner-timeline li.fail::before,
  .inner-timeline li.alert::before,
  .inner-timeline li.crash::before { background: var(--bad); }
  .inner-timeline li.network::before { background: #6b5b95; }
  .inner-timeline li.navigate::before { background: #1e4a8c; }
  .inner-timeline .ev-type {
    font-size: 11px; font-weight: 700; letter-spacing: 0.04em;
    text-transform: uppercase; color: var(--muted);
  }
  .inner-timeline .ev-label { font-weight: 600; margin: 2px 0; word-break: break-word; }
  .inner-timeline .ev-meta { font-size: 12px; color: var(--muted); }
  .badge.crash-kind { background: #fdecec; color: var(--bad); }
  .badge.crash-fatal { background: #fdecec; color: var(--bad); }
  .badge.crash-soft { background: #fff4e5; color: #9a5b00; }
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
  /* Alerts / crashes are peer events (same indent as action). */
  .inner-timeline li.alert,
  .inner-timeline li.crash {
    margin-left: 0;
    border-left: none;
    padding-left: 16px;
    background: transparent;
    border-radius: 0;
  }
  .alert-inline {
    background: transparent; border: none;
    padding: 2px 0 0; margin-top: 0; display:grid; gap: 2px;
  }
  .alert-inline ul.alert-values {
    margin: 4px 0 0; padding-left: 1.2em; font-size: 12px; color: var(--text);
  }
  .alert-inline ul.alert-values li { margin: 2px 0; }
  .alert-inline .alert-metric { font-size: 12px; color: var(--muted); }
  .alert-inline details.alert-stack-card {
    margin: 4px 0 0; border: none; border-radius: 0;
    background: transparent; padding: 0;
  }
  .alert-inline details.alert-stack-card > summary {
    cursor: pointer; font-size: 12px; color: var(--muted); padding: 2px 0;
    list-style: none; user-select: none;
  }
  .alert-inline details.alert-stack-card > summary::-webkit-details-marker { display: none; }
  .alert-inline details.alert-stack-card > summary::before {
    content: "▸ "; font-size: 11px;
  }
  .alert-inline details.alert-stack-card[open] > summary::before { content: "▾ "; }
  .alert-inline pre.alert-stack {
    margin: 4px 0 0; padding: 8px 10px; font-size: 11px; line-height: 1.35;
    overflow: auto; max-height: 220px; white-space: pre-wrap; word-break: break-all;
    background: #0f1a14; color: #d7ece1; border-radius: 6px;
  }
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
      var show = filter === 'all' || m === filter ||
        (filter === 'lifecycle' && (m === 'lifecycle' || m === 'startup'));
      li.classList.toggle('hidden', !show);
    });
  });
})();
''';

String _clearScript() => r'''
(function () {
  var btn = document.getElementById('btn-clear');
  if (!btn) return;
  function clearUrl() {
    if (location.protocol === 'http:' || location.protocol === 'https:') {
      return location.origin + '/report/clear';
    }
    return 'http://127.0.0.1:19288/report/clear';
  }
  btn.addEventListener('click', function () {
    if (!confirm('清空当前会话报告？步骤与告警将从 App 账本抹掉（会话 id 保留）。')) {
      return;
    }
    btn.disabled = true;
    btn.textContent = 'Clearing…';
    fetch(clearUrl(), { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        if (!res.ok || (res.j && res.j.code !== 0 && res.j.code !== undefined && res.j.code !== '0')) {
          var msg = (res.j && (res.j.msg || res.j.message)) || 'clear failed';
          alert(msg);
          btn.disabled = false;
          btn.textContent = 'Clear';
          return;
        }
        location.reload();
      })
      .catch(function (e) {
        alert('Clear 需要 App Bridge（默认 :19288）。\n' + e);
        btn.disabled = false;
        btn.textContent = 'Clear';
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
    'startup' || 'lifecycle' => '生命周期',
    'transition' => '转场',
    'alert' => '性能报告(旧)', // legacy JSON only
    _ => '页面',
  };
  final badges = StringBuffer()
    ..write('<span class="badge mod-$module">$modLabel</span> ');
  if (module == 'lifecycle' || module == 'startup') {
    final kind = seg['kind']?.toString() ?? 'cold_start';
    badges.write(
      '<span class="badge net">${_esc(kind)}</span> ',
    );
  }
  if (module == 'page') {
    final actions = seg['actionCount'] ?? 0;
    final nets = seg['networkCount'] ?? 0;
    final alerts = seg['alertCount'] ?? 0;
    badges
      ..write('<span class="badge net">$actions 操作</span> ')
      ..write('<span class="badge net">$nets 请求</span>');
    if (alerts is num && alerts > 0) {
      badges.write(' <span class="badge bad">$alerts 告警</span>');
    }
  }
  if (module == 'transition') {
    badges.write(
      '<span class="badge net">${_esc(seg['transitionKind']?.toString() ?? 'unknown')}</span>',
    );
    final alerts = seg['alertCount'] ?? 0;
    if (alerts is num && alerts > 0) {
      badges.write(' <span class="badge bad">$alerts 告警</span>');
    }
  }

  final headerExtra = switch (module) {
    'startup' || 'lifecycle' => _lifecycleExtrasHtml(seg),
    'page' => _pageExtrasHtml(seg),
    'transition' => _transitionExtrasHtml(seg),
    'alert' => _perfReportExtrasHtml(seg), // legacy view.timeline
    _ => '',
  };

  final events =
      (seg['events'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final isLifecycle = module == 'startup' || module == 'lifecycle';
  final showInner = !isLifecycle || events.length > 1;
  final emptyPage = module == 'page' && events.isEmpty;

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
  ${emptyPage ? '<p class="muted">无操作</p>' : (showInner ? _innerEventsHtml(events) : '')}
</article>''';
}

String _lifecycleExtrasHtml(Map<String, dynamic> seg) {
  final kind = seg['kind']?.toString() ?? 'cold_start';
  if (kind == 'cold_start') {
    return '''
  <div class="metrics">
    <div><label>TTFF</label><b>${_num(seg['ttffMs'])} ms</b></div>
    <div><label>TTI</label><b>${_num(seg['ttiMs'])} ms</b></div>
    <div><label>Engine TTFF</label><b>${_num(seg['engineTtffMs'])} ms</b></div>
  </div>
  ${_coldStartPhasesHtml(seg)}''';
  }
  final route = seg['route']?.toString();
  final bg = seg['backgroundMs'];
  final buf = StringBuffer();
  if (route != null && route.isNotEmpty) {
    buf.writeln('<p class="seg-meta">当时路由 <code>${_esc(route)}</code></p>');
  }
  if (bg != null) {
    buf.writeln('<p class="seg-meta">后台时长 ${_num(bg)} ms</p>');
  }
  return buf.toString();
}

String _pageExtrasHtml(Map<String, dynamic> seg) => _pageDiffsHtml(seg);

String _perfReportExtrasHtml(Map<String, dynamic> seg) {
  final buf = StringBuffer();
  final owner = seg['ownerRoute']?.toString();
  if (owner != null && owner.isNotEmpty) {
    buf.writeln(
      '<p class="seg-meta">所属页面：<code>${_esc(owner)}</code></p>',
    );
  }
  final summary =
      (seg['pageSummary'] as Map?)?.cast<String, dynamic>() ?? const {};
  if (summary.isEmpty) return buf.toString();
  buf.writeln('<div class="metrics">');
  if (summary['dwellMs'] != null) {
    buf.writeln(
      '<div><label>停留</label><b>${_num(summary['dwellMs'])} ms</b></div>',
    );
  }
  buf.writeln(
    '<div><label>操作</label><b>${summary['actionCount'] ?? 0}</b></div>',
  );
  buf.writeln(
    '<div><label>请求</label><b>${summary['networkCount'] ?? 0}</b></div>',
  );
  buf.writeln(
    '<div><label>慢请求</label><b>${summary['slowRequestCount'] ?? 0}</b></div>',
  );
  if (summary['memoryDeltaMb'] != null) {
    buf.writeln(
      '<div><label>ΔRSS</label><b>${_num(summary['memoryDeltaMb'])} MB</b></div>',
    );
  }
  buf.writeln('</div>');
  return buf.toString();
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
    final type = t['type']?.toString() ?? 'action';
    if (type == 'screenshot') continue; // path narrative: no screenshots
    i++;
    final id = t['id']?.toString() ?? 'ev_$i';
    final label = t['label']?.toString() ?? type;
    final ok = t['ok'] != false;
    final at = _fmtTime(t['at']?.toString());
    final detail =
        (t['detail'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final source = t['source']?.toString();
    final alertType = type == 'alert'
        ? (detail['alertType']?.toString() ??
            detail['type']?.toString() ??
            'alert')
        : null;
    final value = detail['value'];
    final valueMap = value is Map ? Map<String, dynamic>.from(value) : null;
    final isCrash = alertType == 'crash' ||
        valueMap?['source']?.toString() == 'crash_capture';

    final cls = [
      if (isCrash) 'crash' else type,
      if (!ok && !isCrash) 'fail',
      if (type == 'alert' && !isCrash) 'fail',
    ].join(' ');
    final meta = <String>[];
    if (at.isNotEmpty) meta.add(at);
    if (t['stepId'] != null) meta.add(t['stepId'].toString());
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
    String displayType = type;
    var displayLabel = label;
    var typeBadges = '';
    if (type == 'alert') {
      displayType = isCrash ? 'exception' : (alertType ?? 'alert');
      if (isCrash) {
        final kind = valueMap?['kind']?.toString() ?? 'crash';
        final fatal = valueMap?['fatal'] == true;
        typeBadges =
            ' <span class="badge crash-kind">${_esc(kind)}</span>'
            ' <span class="badge ${fatal ? 'crash-fatal' : 'crash-soft'}">'
            '${fatal ? 'fatal' : 'non-fatal'}</span>';
        if (valueMap?['route'] != null) {
          meta.add(valueMap!['route'].toString());
        }
        if (valueMap?['library'] != null) {
          meta.add('lib=${valueMap!['library']}');
        }
        // Prefer error text as the main line (already cleaned in view label).
        if (displayLabel.startsWith('crash ·') ||
            displayLabel == 'crash' ||
            displayLabel.startsWith('FlutterError') ||
            displayLabel.startsWith('未捕获异常')) {
          final err = valueMap?['error']?.toString();
          if (err != null && err.isNotEmpty) displayLabel = err;
        }
      } else {
        final sev = _shortSevFromDetail(detail);
        if (sev != null) meta.add(sev);
        if (displayLabel == alertType ||
            displayLabel.startsWith('$alertType:')) {
          if (valueMap?['title'] != null) {
            displayLabel = valueMap!['title'].toString();
          } else if (detail['message'] != null) {
            displayLabel = detail['message'].toString();
          }
        }
      }
    }
    final srcBadge = (type == 'action' && source != null && source.isNotEmpty)
        ? ' <span class="badge src-$source">${_esc(source)}</span>'
        : '';
    // Crash uses kind/fatal badges; other failed actions keep 「失败」.
    final failBadge =
        (!ok && !isCrash) ? ' <span class="badge bad">失败</span>' : '';
    final netExpand = type == 'network' ? _networkExpandHtml(detail) : '';
    final alertBox = type == 'alert'
        ? '<div class="alert-inline">${_alertValueHtml(detail)}</div>'
        : '';
    items.add('''
<li id="$id" class="$cls" data-type="${_esc(isCrash ? 'exception' : type)}">
  <div class="ev-type">$i · ${_esc(displayType)}$srcBadge$typeBadges$failBadge</div>
  <div class="ev-label">${_esc(displayLabel)}</div>
  ${meta.isEmpty ? '' : '<div class="ev-meta">${_esc(meta.join(' · '))}</div>'}
  $netExpand
  $alertBox
</li>''');
  }
  if (items.isEmpty) return '<p class="muted">无操作</p>';
  return '<ol class="inner-timeline">${items.join('\n')}</ol>';
}

/// D1 crash body — kind/fatal/route live in the event header; here only extras.
String _crashAlertHtml(
  Map<String, dynamic> m,
  String Function(String, [int]) clip,
) {
  final ctx = m['context']?.toString();
  final stack = m['stack']?.toString();
  final ctxHtml = (ctx != null && ctx.isNotEmpty)
      ? '<div class="alert-metric muted">${_esc(clip(ctx, 120))}</div>'
      : '';
  var stackHtml = '';
  if (stack != null && stack.isNotEmpty) {
    final n = stack
        .trimRight()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .length;
    final label = n > 0 ? '堆栈 · $n 行' : '堆栈';
    stackHtml = '<details class="alert-stack-card">'
        '<summary>$label</summary>'
        '<pre class="alert-stack">${_esc(clip(stack, 1200))}</pre>'
        '</details>';
  }
  return '$ctxHtml$stackHtml';
}

/// Sleuth / latch issue body — title lives in ev-label; here detail + fix only.
String _memoryPressureHtml(
  Map<String, dynamic> m,
  String Function(String, [int]) clip,
) {
  final title = m['title']?.toString();
  final detail = m['detail']?.toString() ?? m['message']?.toString();
  final fix = m['fixHint']?.toString();
  final detailHtml = (detail != null &&
          detail.isNotEmpty &&
          detail != title)
      ? '<div class="alert-metric muted">${_esc(clip(detail, 220))}</div>'
      : '';
  final fixHtml = (fix != null && fix.isNotEmpty)
      ? '<div class="alert-metric muted">fix: ${_esc(clip(fix, 160))}</div>'
      : '';
  if (detailHtml.isEmpty && fixHtml.isEmpty && title != null) {
    // Fallback when only title exists (already shown as label).
    return '';
  }
  return '$detailHtml$fixHtml';
}

String? _shortSevFromDetail(Map<String, dynamic> detail) {
  final v = detail['value'];
  Object? raw;
  if (v is Map) raw = v['severity'];
  raw ??= detail['severity'];
  if (raw == null) return null;
  final s = raw.toString().toLowerCase();
  if (s.contains('critical')) return 'critical';
  if (s.contains('error')) return 'error';
  if (s.contains('warning')) return 'warning';
  if (s.contains('info')) return 'info';
  final full = raw.toString();
  final dot = full.lastIndexOf('.');
  if (dot >= 0 && dot < full.length - 1) {
    return full.substring(dot + 1).toLowerCase();
  }
  return null;
}

/// D0 FrameVerdict fields for realtime jank / slow_frame.
String _jankVerdictHtml(
  Map<String, dynamic> m,
  String Function(String, [int]) clip,
) {
  final bits = <String>[];
  void add(String key, String label) {
    final v = m[key];
    if (v == null) return;
    bits.add('$label=${_esc(v.toString())}');
  }

  add('frameMs', 'frame');
  add('uiMs', 'ui');
  add('rasterMs', 'raster');
  add('buildMs', 'build');
  add('layoutMs', 'layout');
  add('paintMs', 'paint');
  add('suspectedPhase', 'phase');
  add('vmMode', 'vm');
  final reason = m['reason']?.toString();
  final head = bits.isEmpty
      ? ''
      : '<div class="alert-metric">${bits.join(' · ')}</div>';
  final reasonHtml = (reason != null && reason.isNotEmpty)
      ? '<div class="alert-metric muted">${_esc(clip(reason, 220))}</div>'
      : '';

  final related = m['relatedIssues'];
  var relatedHtml = '';
  if (related is List && related.isNotEmpty) {
    final items = <String>[];
    for (final e in related.take(6)) {
      if (e is! Map) continue;
      final title = e['title']?.toString() ??
          e['stableId']?.toString() ??
          e.toString();
      final sev = e['severity']?.toString();
      final line = sev != null && sev.isNotEmpty
          ? '${clip(title)} · $sev'
          : clip(title);
      items.add('<li>${_esc(line)}</li>');
    }
    if (items.isNotEmpty) {
      relatedHtml =
          '<div class="alert-metric">相关 issue</div><ul class="alert-values">${items.join()}</ul>';
    }
  }

  final tops = m['topFunctions'];
  var topHtml = '';
  if (tops is List && tops.isNotEmpty) {
    final items = <String>[];
    for (final e in tops.take(5)) {
      if (e is Map) {
        final name = e['name']?.toString() ??
            e['function']?.toString() ??
            e['uri']?.toString() ??
            e.toString();
        items.add('<li>${_esc(clip(name, 100))}</li>');
      } else {
        items.add('<li>${_esc(clip(e.toString(), 100))}</li>');
      }
    }
    topHtml =
        '<div class="alert-metric">Top 函数</div><ul class="alert-values">${items.join()}</ul>';
  }

  return '$head$reasonHtml$relatedHtml$topHtml';
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
    final alertType = detail['type']?.toString() ?? detail['alertType']?.toString();
    if (alertType == 'jank' || alertType == 'slow_frame') {
      return _jankVerdictHtml(m, clip);
    }
    if (alertType == 'crash' || m['source']?.toString() == 'crash_capture') {
      return _crashAlertHtml(m, clip);
    }
    if (m['source']?.toString() == 'sleuth_issue_latch' ||
        m['source']?.toString() == 'sleuth_expand' ||
        m['source']?.toString() == 'mcp_diff' ||
        m['source']?.toString() == 'mcp_diff_expand' ||
        alertType == 'gc_pressure' ||
        alertType == 'heap_growing' ||
        alertType == 'heap_near_capacity' ||
        alertType == 'native_memory_growing' ||
        alertType == 'sustained_jank' ||
        alertType == 'raster_dominance' ||
        alertType == 'shader_compilation' ||
        alertType == 'heavy_compute' ||
        alertType == 'platform_channel_traffic' ||
        alertType == 'stream_resource_growth' ||
        alertType == 'rebuild_activity' ||
        alertType == 'excessive_repaint' ||
        alertType == 'missing_repaint_boundary' ||
        alertType == 'layout_bottleneck' ||
        alertType == 'non_lazy_list' ||
        alertType == 'setstate_scope' ||
        alertType == 'slow_request' ||
        alertType == 'large_response') {
      return _memoryPressureHtml(m, clip);
    }
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
    final sleuthHits = m['sleuthHits'];
    if (sleuthHits is List && sleuthHits.isNotEmpty) {
      final hits = sleuthHits.take(3).map((e) {
        if (e is Map) {
          return e['title']?.toString() ??
              e['stableId']?.toString() ??
              e.toString();
        }
        return e.toString();
      }).join('；');
      bits.add('sleuth: ${clip(hits, 120)}');
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
