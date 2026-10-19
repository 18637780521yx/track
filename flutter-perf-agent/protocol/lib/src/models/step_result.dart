import 'action_result.dart';
import 'alert_item.dart';
import 'network_request.dart';
import 'perf_diff_data.dart';
import 'sleuth_data.dart';
import 'step_event.dart';

class StepResult {
  const StepResult({
    required this.stepId,
    required this.action,
    required this.ok,
    required this.driver,
    this.route,
    this.actionResult,
    this.diff,
    this.metricsSource = 'sleuth_bridge',
    this.sleuthIssues,
    this.networkRequests = const [],
    this.events = const [],
    this.alerts = const [],
    this.screenshotPath,
    this.screenshotDataUri,
    this.at,
    this.extra = const {},
  });

  final String stepId;

  /// Primary label. Route chapters use `route:<path>`; cold start uses `cold_start`.
  final String action;

  /// Logical page for this chapter, e.g. `/login`, `/home#mine`.
  final String? route;

  final bool ok;
  final String driver;
  final ActionResult? actionResult;
  final PerfDiffData? diff;
  final String metricsSource;
  final SleuthIssuesData? sleuthIssues;
  final List<NetworkRequest> networkRequests;

  /// Linear timeline inside this route chapter.
  final List<StepEvent> events;

  final List<AlertItem> alerts;
  final String? screenshotPath;
  final String? screenshotDataUri;
  final String? at;
  final Map<String, dynamic> extra;

  StepResult copyWith({
    String? action,
    String? route,
    bool? ok,
    String? driver,
    ActionResult? actionResult,
    PerfDiffData? diff,
    SleuthIssuesData? sleuthIssues,
    List<NetworkRequest>? networkRequests,
    List<StepEvent>? events,
    List<AlertItem>? alerts,
    String? screenshotPath,
    String? screenshotDataUri,
    String? at,
    Map<String, dynamic>? extra,
  }) =>
      StepResult(
        stepId: stepId,
        action: action ?? this.action,
        route: route ?? this.route,
        ok: ok ?? this.ok,
        driver: driver ?? this.driver,
        actionResult: actionResult ?? this.actionResult,
        diff: diff ?? this.diff,
        metricsSource: metricsSource,
        sleuthIssues: sleuthIssues ?? this.sleuthIssues,
        networkRequests: networkRequests ?? this.networkRequests,
        events: events ?? this.events,
        alerts: alerts ?? this.alerts,
        screenshotPath: screenshotPath ?? this.screenshotPath,
        screenshotDataUri: screenshotDataUri ?? this.screenshotDataUri,
        at: at ?? this.at,
        extra: extra ?? this.extra,
      );

  Map<String, dynamic> toJson({bool includeScreenshotDataUri = true}) => {
        'stepId': stepId,
        'action': action,
        if (route != null && route!.isNotEmpty) 'route': route,
        'ok': ok,
        'driver': driver,
        if (actionResult != null) 'actionResult': actionResult!.toJson(),
        if (diff != null) 'diff': diff!.toJson(),
        'metricsSource': metricsSource,
        if (sleuthIssues != null) 'sleuthIssues': sleuthIssues!.toJson(),
        'networkRequests': networkRequests.map((r) => r.toJson()).toList(),
        'networkRequestCount': networkRequests.length,
        'events': events
            .map(
              (e) => e.toJson(
                includeScreenshotDataUri: includeScreenshotDataUri,
              ),
            )
            .toList(),
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
      'route',
      'ok',
      'driver',
      'actionResult',
      'diff',
      'metricsSource',
      'sleuthIssues',
      'networkRequests',
      'networkRequestCount',
      'events',
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
    final network = <NetworkRequest>[];
    final rawNet = json['networkRequests'];
    if (rawNet is List) {
      for (final n in rawNet) {
        if (n is Map) {
          network.add(NetworkRequest.fromJson(Map<String, dynamic>.from(n)));
        }
      }
    }
    final events = <StepEvent>[];
    final rawEvents = json['events'];
    if (rawEvents is List) {
      for (final e in rawEvents) {
        if (e is Map) {
          events.add(StepEvent.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }

    return StepResult(
      stepId: json['stepId'] as String? ?? '',
      action: json['action'] as String? ?? '',
      route: json['route']?.toString(),
      ok: json['ok'] == true,
      driver: json['driver'] as String? ?? 'unknown',
      actionResult: actionResult,
      diff: diff,
      metricsSource: json['metricsSource'] as String? ?? 'sleuth_bridge',
      sleuthIssues: issues,
      networkRequests: network,
      events: events,
      alerts: alerts,
      screenshotPath: json['screenshotPath'] as String?,
      screenshotDataUri: json['screenshotDataUri'] as String?,
      at: json['at'] as String?,
      extra: extra,
    );
  }
}
