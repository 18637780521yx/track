import 'action_result.dart';
import 'alert_item.dart';
import 'perf_diff_data.dart';
import 'sleuth_data.dart';

class StepResult {
  const StepResult({
    required this.stepId,
    required this.action,
    required this.ok,
    required this.driver,
    this.actionResult,
    this.diff,
    this.metricsSource = 'sleuth_bridge',
    this.sleuthIssues,
    this.alerts = const [],
    this.screenshotPath,
    this.screenshotDataUri,
    this.at,
    this.extra = const {},
  });

  final String stepId;
  final String action;
  final bool ok;
  final String driver;
  final ActionResult? actionResult;
  final PerfDiffData? diff;
  final String metricsSource;
  final SleuthIssuesData? sleuthIssues;
  final List<AlertItem> alerts;
  final String? screenshotPath;
  final String? screenshotDataUri;
  final String? at;
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson({bool includeScreenshotDataUri = true}) => {
        'stepId': stepId,
        'action': action,
        'ok': ok,
        'driver': driver,
        if (actionResult != null) 'actionResult': actionResult!.toJson(),
        if (diff != null) 'diff': diff!.toJson(),
        'metricsSource': metricsSource,
        if (sleuthIssues != null) 'sleuthIssues': sleuthIssues!.toJson(),
        'alerts': alerts.map((a) => a.toJson()).toList(),
        if (screenshotPath != null) 'screenshotPath': screenshotPath,
        if (includeScreenshotDataUri && screenshotDataUri != null)
          'screenshotDataUri': screenshotDataUri,
        if (at != null) 'at': at,
        ...extra,
      };

  factory StepResult.fromJson(Map<String, dynamic> json) {
    final known = {
      'stepId',
      'action',
      'ok',
      'driver',
      'actionResult',
      'diff',
      'metricsSource',
      'sleuthIssues',
      'alerts',
      'screenshotPath',
      'screenshotDataUri',
      'at',
    };
    final extra = <String, dynamic>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) extra[e.key] = e.value;
    }

    ActionResult? actionResult;
    if (json['actionResult'] is Map) {
      actionResult =
          ActionResult.fromJson(Map<String, dynamic>.from(json['actionResult'] as Map));
    }
    PerfDiffData? diff;
    if (json['diff'] is Map) {
      diff = PerfDiffData.fromJson(Map<String, dynamic>.from(json['diff'] as Map));
    }
    SleuthIssuesData? issues;
    if (json['sleuthIssues'] is Map) {
      issues = SleuthIssuesData.fromJson(
        Map<String, dynamic>.from(json['sleuthIssues'] as Map),
      );
    }
    final alerts = <AlertItem>[];
    final rawAlerts = json['alerts'];
    if (rawAlerts is List) {
      for (final a in rawAlerts) {
        if (a is Map) {
          alerts.add(AlertItem.fromJson(Map<String, dynamic>.from(a)));
        }
      }
    }

    return StepResult(
      stepId: json['stepId'] as String? ?? '',
      action: json['action'] as String? ?? '',
      ok: json['ok'] == true,
      driver: json['driver'] as String? ?? 'unknown',
      actionResult: actionResult,
      diff: diff,
      metricsSource: json['metricsSource'] as String? ?? 'sleuth_bridge',
      sleuthIssues: issues,
      alerts: alerts,
      screenshotPath: json['screenshotPath'] as String?,
      screenshotDataUri: json['screenshotDataUri'] as String?,
      at: json['at'] as String?,
      extra: extra,
    );
  }
}
