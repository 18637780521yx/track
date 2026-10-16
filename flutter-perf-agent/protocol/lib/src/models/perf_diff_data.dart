import 'snapshot_payload.dart';

class PerfDiffData {
  const PerfDiffData({
    required this.durationMs,
    required this.memoryDeltaBytes,
    required this.memoryDeltaMb,
    this.jankDelta,
    this.fpsBefore,
    this.fpsAfter,
    this.p90FrameMsBefore,
    this.p90FrameMsAfter,
    this.issuesBefore = const [],
    this.issuesAfter = const [],
    this.before,
    this.after,
  });

  final int durationMs;
  final int memoryDeltaBytes;
  final double memoryDeltaMb;
  final int? jankDelta;
  final double? fpsBefore;
  final double? fpsAfter;
  final double? p90FrameMsBefore;
  final double? p90FrameMsAfter;
  final List<String> issuesBefore;
  final List<String> issuesAfter;
  final SnapshotPayload? before;
  final SnapshotPayload? after;

  Map<String, dynamic> toJson() => {
        'durationMs': durationMs,
        'memoryDeltaBytes': memoryDeltaBytes,
        'memoryDeltaMb': memoryDeltaMb,
        'jankDelta': jankDelta,
        'fpsBefore': fpsBefore,
        'fpsAfter': fpsAfter,
        'p90FrameMsBefore': p90FrameMsBefore,
        'p90FrameMsAfter': p90FrameMsAfter,
        'issuesBefore': issuesBefore,
        'issuesAfter': issuesAfter,
        if (before != null) 'before': before!.toJson(),
        if (after != null) 'after': after!.toJson(),
      };

  factory PerfDiffData.fromJson(Map<String, dynamic> json) {
    List<String> asStrings(Object? raw) {
      if (raw is! List) return const [];
      return raw.map((e) => e.toString()).toList();
    }

    SnapshotPayload? snap(Object? raw) {
      if (raw is Map) {
        return SnapshotPayload.fromJson(Map<String, dynamic>.from(raw));
      }
      return null;
    }

    return PerfDiffData(
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      memoryDeltaBytes: (json['memoryDeltaBytes'] as num?)?.toInt() ?? 0,
      memoryDeltaMb: (json['memoryDeltaMb'] as num?)?.toDouble() ?? 0,
      jankDelta: (json['jankDelta'] as num?)?.toInt(),
      fpsBefore: (json['fpsBefore'] as num?)?.toDouble(),
      fpsAfter: (json['fpsAfter'] as num?)?.toDouble(),
      p90FrameMsBefore: (json['p90FrameMsBefore'] as num?)?.toDouble(),
      p90FrameMsAfter: (json['p90FrameMsAfter'] as num?)?.toDouble(),
      issuesBefore: asStrings(json['issuesBefore']),
      issuesAfter: asStrings(json['issuesAfter']),
      before: snap(json['before']),
      after: snap(json['after']),
    );
  }

  static PerfDiffData compute({
    required SnapshotPayload before,
    required SnapshotPayload after,
    required int durationMs,
  }) {
    final memoryDeltaBytes = after.rssBytes - before.rssBytes;
    final memoryDeltaMb = memoryDeltaBytes / (1024 * 1024);
    int? jankDelta;
    if (before.jankCount != null && after.jankCount != null) {
      jankDelta = after.jankCount! - before.jankCount!;
    }
    return PerfDiffData(
      durationMs: durationMs,
      memoryDeltaBytes: memoryDeltaBytes,
      memoryDeltaMb: double.parse(memoryDeltaMb.toStringAsFixed(3)),
      jankDelta: jankDelta,
      fpsBefore: before.avgFps,
      fpsAfter: after.avgFps,
      p90FrameMsBefore: before.p90FrameMs,
      p90FrameMsAfter: after.p90FrameMs,
      issuesBefore: before.sleuthIssues,
      issuesAfter: after.sleuthIssues,
      before: before,
      after: after,
    );
  }
}
