class AlertItem {
  const AlertItem({
    required this.type,
    required this.stepId,
    required this.action,
    required this.message,
    this.value,
    this.threshold,
    this.totalIssues,
  });

  final String type;
  final String stepId;
  final String action;
  final String message;
  final Object? value;
  final Object? threshold;
  final int? totalIssues;

  Map<String, dynamic> toJson() => {
        'type': type,
        'stepId': stepId,
        'action': action,
        'message': message,
        if (value != null) 'value': value,
        if (threshold != null) 'threshold': threshold,
        if (totalIssues != null) 'totalIssues': totalIssues,
      };

  factory AlertItem.fromJson(Map<String, dynamic> json) => AlertItem(
        type: json['type'] as String? ?? 'unknown',
        stepId: json['stepId'] as String? ?? '',
        action: json['action'] as String? ?? '',
        message: json['message'] as String? ?? '',
        value: json['value'],
        threshold: json['threshold'],
        totalIssues: (json['totalIssues'] as num?)?.toInt(),
      );
}
