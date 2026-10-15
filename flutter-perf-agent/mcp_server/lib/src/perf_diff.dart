/// Compute a lightweight before/after performance diff on the MCP side.
Map<String, dynamic> computePerfDiff({
  required Map<String, dynamic> before,
  required Map<String, dynamic> after,
  required int durationMs,
}) {
  final beforeRss = (before['rssBytes'] as num?)?.toInt() ?? 0;
  final afterRss = (after['rssBytes'] as num?)?.toInt() ?? 0;
  final memoryDeltaBytes = afterRss - beforeRss;
  final memoryDeltaMb = memoryDeltaBytes / (1024 * 1024);

  final beforeJank = before['jankCount'] as int?;
  final afterJank = after['jankCount'] as int?;
  final jankDelta =
      (beforeJank != null && afterJank != null) ? afterJank - beforeJank : null;

  return {
    'durationMs': durationMs,
    'memoryDeltaBytes': memoryDeltaBytes,
    'memoryDeltaMb': double.parse(memoryDeltaMb.toStringAsFixed(3)),
    'jankDelta': jankDelta,
    'fpsBefore': before['avgFps'],
    'fpsAfter': after['avgFps'],
    'p90FrameMsBefore': before['p90FrameMs'],
    'p90FrameMsAfter': after['p90FrameMs'],
    'issuesBefore': before['sleuthIssues'] ?? const [],
    'issuesAfter': after['sleuthIssues'] ?? const [],
    'before': before,
    'after': after,
  };
}
