import 'dart:convert';

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
          return '''
<article class="step ${ok ? 'ok' : 'fail'}">
  <header>
    <h3>${_esc(s['stepId']?.toString())} · ${_esc(s['action']?.toString())}</h3>
    <div class="meta">
      <span class="badge ${ok ? 'good' : 'bad'}">${ok ? 'OK' : 'FAIL'}</span>
      $alertBadge
      <span class="muted">${_esc(s['driver']?.toString() ?? '')}</span>
    </div>
  </header>
  <p><strong>目标：</strong>${_esc(s['targetDesc']?.toString() ?? s['text']?.toString() ?? '-')}</p>
  <div class="metrics">
    <div><label>耗时</label><b>${diff['durationMs'] ?? '-'} ms</b></div>
    <div><label>内存 Δ</label><b>${_num(diff['memoryDeltaMb'])} MB</b></div>
    <div><label>Jank Δ</label><b>${diff['jankDelta'] ?? '-'}</b></div>
    <div><label>FPS</label><b>${_num(diff['fpsBefore'])} → ${_num(diff['fpsAfter'])}</b></div>
    <div><label>P90</label><b>${_num(diff['p90FrameMsBefore'])} → ${_num(diff['p90FrameMsAfter'])} ms</b></div>
  </div>
  <details>
    <summary>原始 step JSON</summary>
    <pre>${_esc(const JsonEncoder.withIndent('  ').convert(s))}</pre>
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
    --accent: #0b6e4f;
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
  .badge { display:inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; font-weight: 600; }
  .badge.good { background: #e3f5ee; color: var(--good); }
  .badge.bad { background: #fdecec; color: var(--bad); }
  .muted { color: var(--muted); font-size: 13px; }
  details { margin-top: 8px; }
  pre {
    overflow:auto; background:#0f1a14; color:#d7ece1; padding:12px; border-radius:8px;
    font-size: 12px; line-height: 1.4;
  }
  footer { margin-top: 28px; color: var(--muted); font-size: 13px; }
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
  </div>

  <h2>阈值</h2>
  <div class="grid">
    <div class="stat"><label>maxFrameCostMs</label><b>${thresholds['maxFrameCostMs'] ?? '-'}</b></div>
    <div class="stat"><label>memoryIncreaseWarningMB</label><b>${thresholds['memoryIncreaseWarningMB'] ?? '-'}</b></div>
    <div class="stat"><label>slowRequestMs</label><b>${thresholds['slowRequestMs'] ?? '-'}</b></div>
  </div>

  <h2>告警</h2>
  $alertCards

  <h2>步骤时序</h2>
  $stepCards

  <footer>$note</footer>
</main>
</body>
</html>''';
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
