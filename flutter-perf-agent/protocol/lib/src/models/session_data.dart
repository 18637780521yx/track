import 'snapshot_payload.dart';

class SessionStartData {
  const SessionStartData({
    required this.sessionId,
    required this.testName,
    required this.startedAt,
    this.vmServiceUri,
    this.baseline,
  });

  final String sessionId;
  final String testName;
  final String startedAt;
  final String? vmServiceUri;
  final SnapshotPayload? baseline;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'testName': testName,
        'startedAt': startedAt,
        'vmServiceUri': vmServiceUri,
        if (baseline != null) 'baseline': baseline!.toJson(),
      };

  factory SessionStartData.fromJson(Map<String, dynamic> json) {
    SnapshotPayload? baseline;
    final raw = json['baseline'];
    if (raw is Map) {
      baseline = SnapshotPayload.fromJson(Map<String, dynamic>.from(raw));
    }
    return SessionStartData(
      sessionId: json['sessionId'] as String? ?? '',
      testName: json['testName'] as String? ?? '',
      startedAt: json['startedAt'] as String? ?? '',
      vmServiceUri: json['vmServiceUri'] as String?,
      baseline: baseline,
    );
  }
}

class SessionStopData {
  const SessionStopData({
    this.sessionId,
    this.testName,
    this.startedAt,
    this.endedAt,
    this.finalSnapshot,
  });

  final String? sessionId;
  final String? testName;
  final String? startedAt;
  final String? endedAt;
  final SnapshotPayload? finalSnapshot;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'testName': testName,
        'startedAt': startedAt,
        'endedAt': endedAt,
        if (finalSnapshot != null) 'finalSnapshot': finalSnapshot!.toJson(),
      };

  factory SessionStopData.fromJson(Map<String, dynamic> json) {
    SnapshotPayload? snap;
    final raw = json['finalSnapshot'];
    if (raw is Map) {
      snap = SnapshotPayload.fromJson(Map<String, dynamic>.from(raw));
    }
    return SessionStopData(
      sessionId: json['sessionId'] as String?,
      testName: json['testName'] as String?,
      startedAt: json['startedAt'] as String?,
      endedAt: json['endedAt'] as String?,
      finalSnapshot: snap,
    );
  }
}
