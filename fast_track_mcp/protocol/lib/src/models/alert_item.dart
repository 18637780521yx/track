class AlertItem {
  const AlertItem({
    required this.type,
    required this.stepId,
    required this.action,
    required this.message,
    this.value,
    this.threshold,
    this.totalIssues,
    /// Wall-clock time of the underlying signal (e.g. jank frame).
    /// When set, timeline uses this instead of the parent step's `at`.
    this.at,
  });

  final String type;
  final String stepId;
  final String action;
  final String message;
  final Object? value;
  final Object? threshold;
  final int? totalIssues;
  final String? at;

  Map<String, dynamic> toJson() => {
        'type': type,
        'stepId': stepId,
        'action': action,
        'message': message,
        if (value != null) 'value': value,
        if (threshold != null) 'threshold': threshold,
        if (totalIssues != null) 'totalIssues': totalIssues,
        if (at != null && at!.isNotEmpty) 'at': at,
      };

  factory AlertItem.fromJson(Map<String, dynamic> json) => AlertItem(
        type: json['type'] as String? ?? 'unknown',
        stepId: json['stepId'] as String? ?? '',
        action: json['action'] as String? ?? '',
        message: json['message'] as String? ?? '',
        value: json['value'],
        threshold: json['threshold'],
        totalIssues: (json['totalIssues'] as num?)?.toInt(),
        at: json['at']?.toString(),
      );

  AlertItem copyWith({
    String? type,
    String? stepId,
    String? action,
    String? message,
    Object? value,
    Object? threshold,
    int? totalIssues,
    String? at,
  }) =>
      AlertItem(
        type: type ?? this.type,
        stepId: stepId ?? this.stepId,
        action: action ?? this.action,
        message: message ?? this.message,
        value: value ?? this.value,
        threshold: threshold ?? this.threshold,
        totalIssues: totalIssues ?? this.totalIssues,
        at: at ?? this.at,
      );
}
