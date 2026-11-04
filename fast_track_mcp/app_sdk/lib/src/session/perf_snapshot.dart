import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';

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

  SnapshotPayload toPayload() => SnapshotPayload(
        timestampMs: timestampMs,
        rssBytes: rssBytes,
        avgFps: avgFps,
        p90FrameMs: p90FrameMs,
        jankCount: jankCount,
        sleuthIssues: sleuthIssues,
        sleuth: rawSleuthJson,
      );

  Map<String, dynamic> toJson() => toPayload().toJson();

  /// Capture RSS. Frame stats and issue lists stay empty (no external profiler).
  ///
  /// [includeRaw] is accepted for callers that used to request a raw export;
  /// the raw map stays empty.
  static PerfSnapshot capture({bool includeRaw = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rss = (!kIsWeb &&
            (Platform.isAndroid ||
                Platform.isIOS ||
                Platform.isMacOS ||
                Platform.isLinux ||
                Platform.isWindows))
        ? ProcessInfo.currentRss
        : 0;

    return PerfSnapshot(
      timestampMs: now,
      rssBytes: rss,
      sleuthIssues: const [],
      rawSleuthJson: includeRaw ? const <String, dynamic>{} : null,
    );
  }
}

/// Diff between before/after snapshots for one action.
class FastTrackMcpDiff {
  FastTrackMcpDiff({
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

  FastTrackMcpDiffData toData() => FastTrackMcpDiffData.compute(
        before: before.toPayload(),
        after: after.toPayload(),
        durationMs: durationMs,
      );

  Map<String, dynamic> toJson() => toData().toJson();
}
