/// Sleuth startup metrics (TTFF / TTI / first-frame phases) from Bridge.
class StartupMetricsData {
  const StartupMetricsData({this.metrics});

  /// Raw Sleuth [StartupMetrics.toJson] map; null when not yet available.
  final Map<String, dynamic>? metrics;

  double? get ttffMs => (metrics?['ttffMs'] as num?)?.toDouble();
  double? get ttiMs => (metrics?['ttiMs'] as num?)?.toDouble();
  double? get engineTtffMs => (metrics?['engineTtffMs'] as num?)?.toDouble();
  double? get preDartOverheadMs =>
      (metrics?['preDartOverheadMs'] as num?)?.toDouble();
  double? get frameworkInitMs =>
      (metrics?['frameworkInitMs'] as num?)?.toDouble();

  Map<String, dynamic> toJson() => {
        if (metrics != null) ...metrics!,
        'available': metrics != null,
      };

  factory StartupMetricsData.fromJson(Map<String, dynamic> json) {
    final copy = Map<String, dynamic>.from(json)..remove('available');
    if (copy.isEmpty) return const StartupMetricsData();
    return StartupMetricsData(metrics: copy);
  }
}
