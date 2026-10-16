class SleuthDiagnoseData {
  const SleuthDiagnoseData({
    this.initialized,
    this.captureMode,
    this.vmConnected,
    this.advisory,
  });

  final bool? initialized;
  final String? captureMode;
  final bool? vmConnected;
  final String? advisory;

  Map<String, dynamic> toJson() => {
        'initialized': initialized,
        'captureMode': captureMode,
        'vmConnected': vmConnected,
        'advisory': advisory,
      };

  factory SleuthDiagnoseData.fromJson(Map<String, dynamic> json) =>
      SleuthDiagnoseData(
        initialized: json['initialized'] as bool?,
        captureMode: json['captureMode']?.toString(),
        vmConnected: json['vmConnected'] as bool?,
        advisory: json['advisory'] as String?,
      );
}

class SleuthSummaryData {
  const SleuthSummaryData({this.markdown});

  final String? markdown;

  Map<String, dynamic> toJson() => {'markdown': markdown};

  factory SleuthSummaryData.fromJson(Map<String, dynamic> json) =>
      SleuthSummaryData(markdown: json['markdown'] as String?);
}

class SleuthSnapshotData {
  const SleuthSnapshotData({
    required this.kind,
    this.markdown,
    this.snapshot,
  });

  final String kind;
  final String? markdown;
  final Object? snapshot;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (markdown != null) 'markdown': markdown,
        if (snapshot != null) 'snapshot': snapshot,
      };

  factory SleuthSnapshotData.fromJson(Map<String, dynamic> json) =>
      SleuthSnapshotData(
        kind: json['kind'] as String? ?? 'snapshot',
        markdown: json['markdown'] as String?,
        snapshot: json['snapshot'],
      );
}

class SleuthIssueItem {
  const SleuthIssueItem({
    this.stableId,
    this.id,
    this.title,
    this.severity,
    this.category,
    this.fixHint,
    this.detail,
    this.raw,
  });

  final String? stableId;
  final String? id;
  final String? title;
  final String? severity;
  final String? category;
  final String? fixHint;
  final String? detail;
  final Map<String, dynamic>? raw;

  Map<String, dynamic> toJson() {
    if (raw != null) return Map<String, dynamic>.from(raw!);
    return {
      if (stableId != null) 'stableId': stableId,
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (severity != null) 'severity': severity,
      if (category != null) 'category': category,
      if (fixHint != null) 'fixHint': fixHint,
      if (detail != null) 'detail': detail,
    };
  }

  factory SleuthIssueItem.fromJson(Map<String, dynamic> json) => SleuthIssueItem(
        stableId: json['stableId']?.toString(),
        id: json['id']?.toString(),
        title: json['title']?.toString() ?? json['message']?.toString(),
        severity: json['severity']?.toString(),
        category: json['category']?.toString(),
        fixHint: json['fixHint']?.toString(),
        detail: json['detail']?.toString(),
        raw: Map<String, dynamic>.from(json),
      );
}

class SleuthIssuesData {
  const SleuthIssuesData({
    required this.count,
    required this.issues,
  });

  final int count;
  final List<SleuthIssueItem> issues;

  Map<String, dynamic> toJson() => {
        'count': count,
        'issues': issues.map((e) => e.toJson()).toList(),
      };

  factory SleuthIssuesData.fromJson(Map<String, dynamic> json) {
    final list = <SleuthIssueItem>[];
    final raw = json['issues'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          list.add(SleuthIssueItem.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return SleuthIssuesData(
      count: (json['count'] as num?)?.toInt() ?? list.length,
      issues: list,
    );
  }
}

class SleuthRouteEntry {
  const SleuthRouteEntry({
    required this.routeName,
    this.healthScore,
    this.scaffoldHashKey,
    this.tabVisitIndex,
  });

  final String routeName;
  final num? healthScore;
  final String? scaffoldHashKey;
  final int? tabVisitIndex;

  Map<String, dynamic> toJson() => {
        'routeName': routeName,
        'healthScore': healthScore,
        'scaffoldHashKey': scaffoldHashKey,
        'tabVisitIndex': tabVisitIndex,
      };

  factory SleuthRouteEntry.fromJson(Map<String, dynamic> json) =>
      SleuthRouteEntry(
        routeName: json['routeName']?.toString() ?? '',
        healthScore: json['healthScore'] as num?,
        scaffoldHashKey: json['scaffoldHashKey']?.toString(),
        tabVisitIndex: (json['tabVisitIndex'] as num?)?.toInt(),
      );
}

class SleuthRouteHealthData {
  const SleuthRouteHealthData({
    this.routeName,
    this.healthScore,
    this.routes,
  });

  final String? routeName;
  final num? healthScore;
  final List<SleuthRouteEntry>? routes;

  Map<String, dynamic> toJson() => {
        if (routeName != null) 'routeName': routeName,
        if (healthScore != null) 'healthScore': healthScore,
        if (routes != null)
          'routes': routes!.map((e) => e.toJson()).toList(),
      };

  factory SleuthRouteHealthData.fromJson(Map<String, dynamic> json) {
    List<SleuthRouteEntry>? routes;
    final raw = json['routes'];
    if (raw is List) {
      routes = [
        for (final item in raw)
          if (item is Map)
            SleuthRouteEntry.fromJson(Map<String, dynamic>.from(item)),
      ];
    }
    return SleuthRouteHealthData(
      routeName: json['routeName'] as String?,
      healthScore: json['healthScore'] as num?,
      routes: routes,
    );
  }
}
