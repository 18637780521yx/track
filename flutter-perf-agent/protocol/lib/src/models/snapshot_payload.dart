/// Bridge `/snapshot` payload (RSS + optional Sleuth summary fields).
class SnapshotPayload {
  const SnapshotPayload({
    required this.timestampMs,
    required this.rssBytes,
    this.rssMb,
    this.avgFps,
    this.p90FrameMs,
    this.jankCount,
    this.sleuthIssues = const [],
    this.sleuth,
  });

  final int timestampMs;
  final int rssBytes;
  final double? rssMb;
  final double? avgFps;
  final double? p90FrameMs;
  final int? jankCount;
  final List<String> sleuthIssues;
  final Map<String, dynamic>? sleuth;

  double get rssMbOrComputed =>
      rssMb ?? double.parse((rssBytes / (1024 * 1024)).toStringAsFixed(2));

  Map<String, dynamic> toJson() => {
        'timestampMs': timestampMs,
        'rssBytes': rssBytes,
        'rssMb': rssMbOrComputed,
        'avgFps': avgFps,
        'p90FrameMs': p90FrameMs,
        'jankCount': jankCount,
        'sleuthIssues': sleuthIssues,
        if (sleuth != null) 'sleuth': sleuth,
      };

  factory SnapshotPayload.fromJson(Map<String, dynamic> json) {
    final issues = <String>[];
    final rawIssues = json['sleuthIssues'];
    if (rawIssues is List) {
      for (final i in rawIssues) {
        issues.add(i.toString());
      }
    }
    return SnapshotPayload(
      timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
      rssBytes: (json['rssBytes'] as num?)?.toInt() ?? 0,
      rssMb: (json['rssMb'] as num?)?.toDouble(),
      avgFps: (json['avgFps'] as num?)?.toDouble(),
      p90FrameMs: (json['p90FrameMs'] as num?)?.toDouble(),
      jankCount: (json['jankCount'] as num?)?.toInt(),
      sleuthIssues: issues,
      sleuth: json['sleuth'] is Map
          ? Map<String, dynamic>.from(json['sleuth'] as Map)
          : null,
    );
  }
}

/// Wrapper for Bridge snapshot endpoint data field.
class SnapshotData {
  const SnapshotData({required this.snapshot});

  final SnapshotPayload snapshot;

  Map<String, dynamic> toJson() => {'snapshot': snapshot.toJson()};

  factory SnapshotData.fromJson(Map<String, dynamic> json) {
    final snap = json['snapshot'];
    return SnapshotData(
      snapshot: snap is Map
          ? SnapshotPayload.fromJson(Map<String, dynamic>.from(snap))
          : SnapshotPayload(timestampMs: 0, rssBytes: 0),
    );
  }
}
