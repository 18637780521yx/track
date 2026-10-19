/// One linear event inside a route chapter ([StepResult]).
class StepEvent {
  const StepEvent({
    required this.type,
    required this.at,
    this.label,
    this.ok = true,
    this.screenshotPath,
    this.screenshotDataUri,
    this.detail = const {},
  });

  /// `screenshot` | `action` | `network` | `navigate` | `cold_start`
  final String type;
  final String at;
  final String? label;
  final bool ok;
  final String? screenshotPath;
  final String? screenshotDataUri;
  final Map<String, dynamic> detail;

  Map<String, dynamic> toJson({bool includeScreenshotDataUri = true}) => {
        'type': type,
        'at': at,
        if (label != null) 'label': label,
        'ok': ok,
        if (screenshotPath != null) 'screenshotPath': screenshotPath,
        if (includeScreenshotDataUri && screenshotDataUri != null)
          'screenshotDataUri': screenshotDataUri,
        if (detail.isNotEmpty) 'detail': detail,
      };

  factory StepEvent.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> detail = const {};
    final raw = json['detail'];
    if (raw is Map) {
      detail = Map<String, dynamic>.from(raw);
    }
    return StepEvent(
      type: json['type']?.toString() ?? 'action',
      at: json['at']?.toString() ?? '',
      label: json['label']?.toString(),
      ok: json['ok'] != false,
      screenshotPath: json['screenshotPath'] as String?,
      screenshotDataUri: json['screenshotDataUri'] as String?,
      detail: detail,
    );
  }
}
