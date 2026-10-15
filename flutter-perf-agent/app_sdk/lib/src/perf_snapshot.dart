import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sleuth/sleuth.dart';

/// Lightweight performance snapshot taken around a UI action.
class PerfSnapshot {
  PerfSnapshot({
    required this.timestampMs,
    required this.rssBytes,
    this.avgFps,
    this.p90FrameMs,
    this.jankCount,
    this.sleuthIssues = const [],
    this.rawSleuthJson,
  });

  final int timestampMs;
  final int rssBytes;
  final double? avgFps;
  final double? p90FrameMs;
  final int? jankCount;
  final List<String> sleuthIssues;
  final Map<String, dynamic>? rawSleuthJson;

  Map<String, dynamic> toJson() => {
        'timestampMs': timestampMs,
        'rssBytes': rssBytes,
        'rssMb': double.parse((rssBytes / (1024 * 1024)).toStringAsFixed(2)),
        'avgFps': avgFps,
        'p90FrameMs': p90FrameMs,
        'jankCount': jankCount,
        'sleuthIssues': sleuthIssues,
        if (rawSleuthJson != null) 'sleuth': rawSleuthJson,
      };

  /// Capture current metrics from Sleuth (+ RSS fallback).
  ///
  /// [sleuth] — when false, only RSS is captured (fast path for session start,
  /// avoids rare hangs in `Sleuth.exportSnapshotJson` on cold start).
  static PerfSnapshot capture({
    bool includeRaw = false,
    bool sleuth = true,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rss = (!kIsWeb && (Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS ||
            Platform.isLinux ||
            Platform.isWindows))
        ? ProcessInfo.currentRss
        : 0;

    double? avgFps;
    double? p90FrameMs;
    int? jankCount;
    final issues = <String>[];
    Map<String, dynamic>? raw;

    if (sleuth) {
      try {
        // Prefer object export first — usually cheaper than full JSON stringify.
        final snap = Sleuth.exportSnapshot();
        if (snap != null) {
          try {
            final dynamic d = snap;
            avgFps = _asDouble(d.throughputFps ?? d.avgFps);
            jankCount = _asInt(d.jankCount);
            p90FrameMs = _asDouble(d.p90FrameMs);
          } catch (_) {}
          try {
            final dynamic d = snap;
            final list = d.currentIssues as List?;
            if (list != null) {
              for (final item in list) {
                issues.add(item.toString());
              }
            }
          } catch (_) {}
        }

        if (includeRaw || avgFps == null) {
          final jsonStr = Sleuth.exportSnapshotJson();
          if (jsonStr != null && jsonStr.isNotEmpty) {
            final decoded = jsonDecode(jsonStr);
            if (decoded is Map<String, dynamic>) {
              raw = includeRaw ? decoded : null;
              avgFps ??= _asDouble(
                decoded['throughputFps'] ??
                    decoded['avgFps'] ??
                    decoded['fps'] ??
                    _dig(decoded, ['frameStats', 'throughputFps']) ??
                    _dig(decoded, ['frameStats', 'avgFps']),
              );
              p90FrameMs ??= _asDouble(
                decoded['p90FrameMs'] ??
                    _dig(decoded, ['frameStats', 'p90FrameMs']) ??
                    _dig(decoded, ['frameStats', 'p90Ms']),
              );
              jankCount ??= _asInt(
                decoded['jankCount'] ??
                    _dig(decoded, ['frameStats', 'jankCount']) ??
                    _dig(decoded, ['frameStats', 'jank']),
              );
              if (issues.isEmpty) {
                final currentIssues = decoded['currentIssues'] ??
                    decoded['issues'] ??
                    _dig(decoded, ['frameStats', 'issues']);
                if (currentIssues is List) {
                  for (final item in currentIssues) {
                    if (item is Map) {
                      final id = item['stableId'] ?? item['id'] ?? item['type'];
                      final title =
                          item['title'] ?? item['message'] ?? item['summary'];
                      issues.add('${id ?? 'issue'}: ${title ?? item}');
                    } else {
                      issues.add(item.toString());
                    }
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        issues.add('sleuth_export_error: $e');
      }
    }

    return PerfSnapshot(
      timestampMs: now,
      rssBytes: rss,
      avgFps: avgFps,
      p90FrameMs: p90FrameMs,
      jankCount: jankCount,
      sleuthIssues: issues,
      rawSleuthJson: raw,
    );
  }

  static Object? _dig(Map<String, dynamic> map, List<String> path) {
    Object? cur = map;
    for (final key in path) {
      if (cur is Map && cur.containsKey(key)) {
        cur = cur[key];
      } else {
        return null;
      }
    }
    return cur;
  }

  static double? _asDouble(Object? v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}

/// Diff between before/after snapshots for one action.
class PerfDiff {
  PerfDiff({
    required this.before,
    required this.after,
    required this.durationMs,
  });

  final PerfSnapshot before;
  final PerfSnapshot after;
  final int durationMs;

  int get memoryDeltaBytes => after.rssBytes - before.rssBytes;

  double get memoryDeltaMb => memoryDeltaBytes / (1024 * 1024);

  int? get jankDelta {
    if (before.jankCount == null || after.jankCount == null) return null;
    return after.jankCount! - before.jankCount!;
  }

  Map<String, dynamic> toJson() => {
        'durationMs': durationMs,
        'memoryDeltaBytes': memoryDeltaBytes,
        'memoryDeltaMb':
            double.parse(memoryDeltaMb.toStringAsFixed(3)),
        'jankDelta': jankDelta,
        'fpsBefore': before.avgFps,
        'fpsAfter': after.avgFps,
        'p90FrameMsBefore': before.p90FrameMs,
        'p90FrameMsAfter': after.p90FrameMs,
        'issuesBefore': before.sleuthIssues,
        'issuesAfter': after.sleuthIssues,
        'before': before.toJson(),
        'after': after.toJson(),
      };
}
