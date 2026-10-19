import 'dart:convert';
import 'dart:io';

import 'cold_start_phases.dart';

/// Build a self-contained HTML report from a report JSON map.
String buildHtmlReport(Map<String, dynamic> report) {
  final testName = _esc(report['testName']?.toString() ?? 'unnamed');
  final sessionId = _esc(report['sessionId']?.toString() ?? '');
  final mode = _esc(report['mode']?.toString() ?? '-');
  final startedAt = _esc(report['startedAt']?.toString() ?? '');
  final endedAt = _esc(report['endedAt']?.toString() ?? '');
  final durationMs = report['durationMs'] ?? '-';
  final summary = (report['summary'] as Map?)?.cast<String, dynamic>() ?? {};
  final alerts =
      (report['alerts'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final steps =
      (report['steps'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  final thresholds =
      (report['thresholds'] as Map?)?.cast<String, dynamic>() ?? {};
  final note = _esc(report['note']?.toString() ?? '');
  final sleuthMd = report['sleuthSummaryMarkdown']?.toString();
  final sleuthDiag =
      (report['sleuthDiagnose'] as Map?)?.cast<String, dynamic>();

  final alertCards = alerts.isEmpty
      ? '<p class="muted">无告警</p>'
      : alerts.map((a) {
          return '''
<div class="alert">
  <strong>${_esc(a['type']?.toString())}</strong>
  <span>${_esc(a['message']?.toString())}</span>
  <small>${_esc(a['stepId']?.toString())} · ${_esc(a['action']?.toString())}</small>
</div>''';
        }).join('\n');

  final stepCards = steps.isEmpty
      ? '<p class="muted">无步骤</p>'
      : steps.map((s) {
          final ok = s['ok'] == true;
          final diff = (s['diff'] as Map?)?.cast<String, dynamic>() ?? {};
          final stepAlerts =
              (s['alerts'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
          final alertBadge = stepAlerts.isEmpty
              ? ''
              : '<span class="badge bad">${stepAlerts.length} 告警</span>';
          final timeline = _timelineHtml(s);
          final netCount = (s['networkRequestCount'] as num?)?.toInt() ??
              ((s['networkRequests'] as List?)?.length ?? 0);
          final eventCount = (s['events'] as List?)?.length ?? 0;
          final netBadge = netCount > 0
              ? '<span class="badge net">$netCount 请求</span>'
              : '';
          final eventBadge = eventCount > 0
              ? '<span class="badge net">$eventCount 事件</span>'
              : '';
          final isCold = s['kind'] == 'cold_start' ||
              s['action']?.toString() == 'cold_start';
          final route = (s['route']?.toString().trim().isNotEmpty == true)
              ? s['route'].toString()
              : (s['action']?.toString().startsWith('route:') == true
                  ? s['action'].toString().substring(6)
                  : null);
          final title = isCold
              ? '${s['stepId']} · 冷启动'
              : (route != null && route.isNotEmpty
                  ? '${s['stepId']} · $route'
                  : '${s['stepId']} · ${s['action']}');
          final coldBadge = isCold
              ? '<span class="badge net">冷启动</span>'
              : '';
          final metricsBlock = isCold
              ? '''
  <div class="metrics">
    <div><label>TTFF</label><b>${_num(s['ttffMs'])} ms</b></div>
    <div><label>TTI</label><b>${_num(s['ttiMs'])} ms</b></div>
    <div><label>Engine TTFF</label><b>${_num(s['engineTtffMs'])} ms</b></div>
    <div><label>方案</label><b>A · 引擎/Dart</b></div>
  </div>'''
              : '''
  <div class="metrics">
    <div><label>耗时</label><b>${diff['durationMs'] ?? '-'} ms</b></div>
    <div><label>RSS Δ</label><b>${_num(diff['memoryDeltaMb'])} MB</b></div>
    <div><label>Jank Δ</label><b>${diff['jankDelta'] ?? '-'}</b></div>
    <div><label>FPS</label><b>${_num(diff['fpsBefore'])} → ${_num(diff['fpsAfter'])}</b></div>
    <div><label>P90</label><b>${_num(diff['p90FrameMsBefore'])} → ${_num(diff['p90FrameMsAfter'])} ms</b></div>
  </div>''';
          final phasesHtml = isCold ? _coldStartPhasesHtml(s) : '';
          final caption = isCold
              ? '冷启动方案 A：引擎/Dart 分阶段耗时（下表）+ 首屏截图。'
              : '路由章内<strong>线性时间线</strong>（截图 → 操作 → 请求 → 跳转）；'
                  '网络事件可展开查看请求/响应详情。';
          return '''
<article class="step ${ok ? 'ok' : 'fail'}">
  <header>
    <h3>${_esc(title)}</h3>
    <div class="meta">
      <span class="badge ${ok ? 'good' : 'bad'}">${ok ? 'OK' : 'FAIL'}</span>
      $coldBadge
      $eventBadge
      $alertBadge
      $netBadge
      <span class="muted">${_esc(s['driver']?.toString() ?? '')}</span>
    </div>
  </header>
  <p><strong>路由：</strong><code>${_esc(route ?? '-')}</code></p>
  $metricsBlock
  $phasesHtml
  <p class="muted shot-caption">$caption</p>
  $timeline
  <details>
    <summary>原始 step JSON</summary>
    <pre>${_esc(_stepJsonForDetails(s))}</pre>
  </details>
</article>''';
        }).join('\n');

  return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Perf Report · $testName</title>
<style>
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
  main { max-width: 920px; margin: 0 auto; padding: 32px 20px 64px; }
  h1 { font-size: 1.75rem; margin: 0 0 8px; letter-spacing: -0.02em; }
  h2 { margin: 32px 0 12px; font-size: 1.15rem; }
  .sub { color: var(--muted); margin: 0 0 24px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit,minmax(140px,1fr)); gap: 12px; }
  .stat, .step, .alert {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px;
  }
  .stat label, .metrics label { display:block; color: var(--muted); font-size: 12px; }
  .stat b { font-size: 1.25rem; }
  .alert { background: var(--warn-bg); border-color: #f3b4ae; margin-bottom: 8px; display:grid; gap: 4px; }
  .step { margin-bottom: 12px; }
  .step.fail { border-color: #f3b4ae; }
  .step header { display:flex; justify-content:space-between; gap:12px; align-items:flex-start; }
  .step h3 { margin: 0; font-size: 1rem; }
  .metrics { display:grid; grid-template-columns: repeat(auto-fit,minmax(110px,1fr)); gap: 10px; margin: 12px 0; }
  .shot { margin: 12px 0; }
  .shot img {
    max-width: 100%; border-radius: 8px; border: 1px solid var(--line);
    background: #0f1a14;
  }
  .badge { display:inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; font-weight: 600; }
  .badge.good { background: #e3f5ee; color: var(--good); }
  .badge.bad { background: #fdecec; color: var(--bad); }
  .badge.net { background: #e8eef8; color: #1e4a8c; }
  .net-section { margin: 12px 0; }
  .net-section > h4 { margin: 0 0 8px; font-size: 0.95rem; }
  .net-route-group { margin-bottom: 14px; }
  .net-route-label {
    font-size: 13px; font-weight: 600; margin: 0 0 6px; color: var(--ink);
  }
  .net-route-label code {
    background: #e8eef8; color: #1e4a8c; padding: 1px 6px; border-radius: 4px;
  }
  .shot-caption { margin: 8px 0 4px; }
  .net-card { margin-bottom: 8px; border: 1px solid var(--line); border-radius: 8px; padding: 8px 12px; background: #fafcfb; }
  .net-card summary { cursor: pointer; }
  .net-url { word-break: break-all; font-size: 12px; color: var(--muted); }
  .net-grid { display:grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 8px; }
  @media (max-width: 720px) { .net-grid { grid-template-columns: 1fr; } }
  .net-grid h4 { margin: 8px 0 4px; font-size: 12px; color: var(--muted); font-weight: 600; }
  .net-grid pre {
    margin: 0; max-height: 280px; overflow: auto;
    background:#0f1a14; color:#d7ece1; padding:10px; border-radius:6px;
    font-size: 11px; line-height: 1.35; white-space: pre-wrap; word-break: break-word;
  }
  .muted { color: var(--muted); font-size: 13px; }
  details { margin-top: 8px; }
  pre {
    overflow:auto; background:#0f1a14; color:#d7ece1; padding:12px; border-radius:8px;
    font-size: 12px; line-height: 1.4;
  }
  footer { margin-top: 28px; color: var(--muted); font-size: 13px; }
  .timeline { margin: 12px 0 4px; padding: 0; list-style: none; }
  .timeline li {
    position: relative; padding: 0 0 14px 20px;
    border-left: 2px solid var(--line);
  }
  .timeline li:last-child { padding-bottom: 0; }
  .timeline li::before {
    content: ""; position: absolute; left: -5px; top: 6px;
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--good);
  }
  .timeline li.fail::before { background: var(--bad); }
  .timeline li.nav::before { background: #1e4a8c; }
  .timeline li.net::before { background: #6b5b95; }
  .timeline .ev-type {
    font-size: 11px; font-weight: 700; letter-spacing: 0.04em;
    text-transform: uppercase; color: var(--muted);
  }
  .timeline .ev-label { font-weight: 600; margin: 2px 0; }
  .timeline .ev-meta { font-size: 12px; color: var(--muted); }
  .timeline .shot { margin-top: 8px; }
  .timeline .shot img { max-width: min(100%, 420px); }
  .timeline-net { margin-top: 8px; }
  .timeline-net summary { font-size: 13px; }
  .phases { margin: 14px 0; }
  .phases h4 { margin: 0 0 8px; font-size: 0.95rem; }
  .phases table { width: 100%; border-collapse: collapse; font-size: 13px; }
  .phases th, .phases td {
    text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line);
    vertical-align: middle;
  }
  .phases th { color: var(--muted); font-weight: 600; font-size: 12px; }
  .phases tr.highlight td { background: #f0faf5; }
  .phases tr.total td { font-weight: 700; }
  .phases .bar-wrap {
    height: 10px; background: #e8eef0; border-radius: 999px; overflow: hidden;
    min-width: 80px;
  }
  .phases .bar {
    height: 100%; background: var(--good); border-radius: 999px;
  }
  .phases .bar.hi { background: #c45c26; }
  .phases .bar.engine { background: #1e4a8c; }
  .phases .bar.post { background: #6b5b95; }
  .phases .note { color: var(--muted); font-size: 12px; }
</style>
</head>
<body>
<main>
  <h1>$testName</h1>
  <p class="sub">session $sessionId · $mode · $startedAt → $endedAt</p>

  <div class="grid">
    <div class="stat"><label>总耗时</label><b>$durationMs ms</b></div>
    <div class="stat"><label>步骤</label><b>${summary['stepCount'] ?? steps.length}</b></div>
    <div class="stat"><label>成功</label><b>${summary['okSteps'] ?? '-'}</b></div>
    <div class="stat"><label>告警</label><b>${summary['alertCount'] ?? alerts.length}</b></div>
    <div class="stat"><label>网络请求</label><b>${summary['networkRequestCount'] ?? '-'}</b></div>
  </div>

  <h2>阈值</h2>
  <div class="grid">
    <div class="stat"><label>maxFrameCostMs</label><b>${thresholds['maxFrameCostMs'] ?? '-'}</b></div>
    <div class="stat"><label>memoryIncreaseWarningMB</label><b>${thresholds['memoryIncreaseWarningMB'] ?? '-'}</b></div>
    <div class="stat"><label>slowRequestMs</label><b>${thresholds['slowRequestMs'] ?? '-'}</b></div>
  </div>

  <h2>Sleuth</h2>
  <div class="grid">
    <div class="stat"><label>vmConnected</label><b>${sleuthDiag?['vmConnected'] ?? '-'}</b></div>
    <div class="stat"><label>initialized</label><b>${sleuthDiag?['initialized'] ?? '-'}</b></div>
    <div class="stat"><label>captureMode</label><b>${sleuthDiag?['captureMode'] ?? '-'}</b></div>
  </div>
  ${sleuthDiag?['advisory'] != null ? '<p class="muted">${_esc(sleuthDiag!['advisory']?.toString())}</p>' : ''}
  ${sleuthMd != null && sleuthMd.isNotEmpty ? '<details open><summary>Sleuth summary</summary><pre>${_esc(sleuthMd)}</pre></details>' : ''}

  <h2>告警</h2>
  $alertCards

  <h2>步骤时序</h2>
  $stepCards

  <footer>$note</footer>
</main>
</body>
</html>''';
}

String _prettyJsonOrMap(Object? raw) {
  if (raw == null) return '';
  try {
    if (raw is Map || raw is List) {
      return _esc(const JsonEncoder.withIndent('  ').convert(raw));
    }
    final s = raw.toString();
    if (s.isEmpty) return '';
    // Try parse JSON string bodies already escaped later.
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
  <h4>冷启动分阶段（方案 A）</h4>
  <p class="muted">占比相对 TTFF；「业务启动」= TTFF − Framework init − 首帧合计，通常是业务优化重点。</p>
  <table>
    <thead>
      <tr>
        <th>阶段</th><th>耗时</th><th>占 TTFF</th><th>占比条</th><th>说明</th>
      </tr>
    </thead>
    <tbody>
      $rows
    </tbody>
  </table>
</section>''';
}

String _timelineHtml(Map<String, dynamic> step) {
  final raw = step['events'];
  if (raw is! List || raw.isEmpty) {
    // Fallback: single cover screenshot when no events yet.
    final shot = _shotFromFields(
      step['screenshotDataUri'] as String?,
      step['screenshotPath'] as String?,
    );
    return shot.isEmpty
        ? '<p class="muted">无事件时间线</p>'
        : shot;
  }
  // Prefer full payloads from step.networkRequests when event.detail is thin.
  final netByKey = <String, Map<String, dynamic>>{};
  final rawNet = step['networkRequests'];
  if (rawNet is List) {
    for (final n in rawNet) {
      if (n is! Map) continue;
      final m = Map<String, dynamic>.from(n);
      netByKey[_netKey(m)] = m;
    }
  }

  final items = <String>[];
  var i = 0;
  for (final e in raw) {
    if (e is! Map) continue;
    i++;
    final m = Map<String, dynamic>.from(e);
    final type = m['type']?.toString() ?? 'action';
    final label = m['label']?.toString() ?? type;
    final ok = m['ok'] != false;
    final at = m['at']?.toString() ?? '';
    var detail = (m['detail'] as Map?)?.cast<String, dynamic>() ?? {};
    if (type == 'network') {
      final full = netByKey[_netKey(detail)];
      if (full != null) detail = {...full, ...detail};
    }
    final cls = [
      if (!ok) 'fail',
      if (type == 'navigate') 'nav',
      if (type == 'network') 'net',
    ].join(' ');
    final meta = <String>[];
    if (at.isNotEmpty) meta.add(at);
    if (type == 'network') {
      if (detail['statusCode'] != null) meta.add('HTTP ${detail['statusCode']}');
      if (detail['durationMs'] != null) meta.add('${detail['durationMs']}ms');
      if (detail['responseBytes'] != null) {
        meta.add('${detail['responseBytes']}B');
      }
      if (detail['route'] != null) meta.add('发起于 ${detail['route']}');
    }
    if (type == 'navigate') {
      meta.add('${detail['from'] ?? '?'} → ${detail['to'] ?? '?'}');
    }
    if (type == 'cold_start' && detail['ttffMs'] != null) {
      meta.add('TTFF ${detail['ttffMs']}ms');
    }
    final shot = _shotFromFields(
      m['screenshotDataUri'] as String?,
      m['screenshotPath'] as String?,
    );
    final netExpand = type == 'network' ? _networkExpandHtml(detail) : '';
    items.add('''
<li class="$cls">
  <div class="ev-type">$i · ${_esc(type)}</div>
  <div class="ev-label">${_esc(label)}</div>
  ${meta.isEmpty ? '' : '<div class="ev-meta">${_esc(meta.join(' · '))}</div>'}
  $shot
  $netExpand
</li>''');
  }
  return '<ol class="timeline">${items.join('\n')}</ol>';
}

String _netKey(Map<String, dynamic> m) =>
    '${m['startedAt']}|${m['method']}|${m['url']}|${m['statusCode']}';

/// Collapsed-by-default request/response detail inside a timeline network event.
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
<details class="net-card timeline-net">
  <summary>
    查看请求详情 · <code>$method</code> $status · ${ms}ms · ${bytes}B
    <span class="muted">$source</span>$routeHtml<br/>
    <span class="net-url">$url</span>
  </summary>
  $errHtml
  <div class="net-grid">
    <div>
      <h4>Request Headers</h4>
      <pre>$reqH</pre>
      <h4>Request Body$reqTrunc</h4>
      <pre>$reqB</pre>
    </div>
    <div>
      <h4>Response Headers</h4>
      <pre>$resH</pre>
      <h4>Response Body$resTrunc</h4>
      <pre>$resB</pre>
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

String _stepJsonForDetails(Map<String, dynamic> step) {
  final copy = Map<String, dynamic>.from(step)..remove('screenshotDataUri');
  final events = copy['events'];
  if (events is List) {
    copy['events'] = [
      for (final e in events)
        if (e is Map)
          (Map<String, dynamic>.from(e)..remove('screenshotDataUri'))
        else
          e,
    ];
  }
  return const JsonEncoder.withIndent('  ').convert(copy);
}

String _esc(String? s) {
  if (s == null) return '';
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

String _num(Object? v) {
  if (v == null) return '-';
  if (v is num) return v.toStringAsFixed(v is int ? 0 : 2);
  return v.toString();
}
