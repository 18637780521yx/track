import 'perf_diff_data.dart';

/// Unified result of a UI action (flutter_skill or legacy Bridge).
class ActionResult {
  const ActionResult({
    required this.success,
    this.driver = 'flutter_skill',
    this.detail,
    this.error,
  });

  final bool success;
  final String driver;
  final Map<String, dynamic>? detail;
  final String? error;

  Map<String, dynamic> toJson() => {
        'success': success,
        'driver': driver,
        if (detail != null) 'detail': detail,
        if (error != null) 'error': error,
      };

  factory ActionResult.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? detail;
    if (json['detail'] is Map) {
      detail = Map<String, dynamic>.from(json['detail'] as Map);
    } else if (json['actionResult'] is Map) {
      detail = Map<String, dynamic>.from(json['actionResult'] as Map);
    } else if (json['action'] is Map) {
      detail = Map<String, dynamic>.from(json['action'] as Map);
    }
    return ActionResult(
      success: json['success'] == true || json['ok'] == true,
      driver: json['driver'] as String? ?? 'unknown',
      detail: detail,
      error: json['error'] as String?,
    );
  }

  /// Parse flutter_skill raw extension map.
  factory ActionResult.fromSkillMap(Map<String, dynamic> raw, {String? error}) {
    final ok = raw['success'] == true ||
        raw['ok'] == true ||
        (raw['result'] is Map &&
            ((raw['result'] as Map)['success'] == true ||
                (raw['result'] as Map)['ok'] == true));
    return ActionResult(
      success: ok,
      driver: 'flutter_skill',
      detail: raw,
      error: error ?? (ok ? null : raw['error']?.toString()),
    );
  }
}

/// Legacy Bridge `/tap` response data.
class TapLegacyData {
  const TapLegacyData({
    required this.legacy,
    required this.action,
    this.diff,
    this.sessionId,
    this.warning,
  });

  final bool legacy;
  final ActionResult action;
  final PerfDiffData? diff;
  final String? sessionId;
  final String? warning;

  Map<String, dynamic> toJson() => {
        'legacy': legacy,
        'action': action.toJson(),
        if (diff != null) 'diff': diff!.toJson(),
        'sessionId': sessionId,
        if (warning != null) 'warning': warning,
      };

  factory TapLegacyData.fromJson(Map<String, dynamic> json) {
    PerfDiffData? diff;
    if (json['diff'] is Map) {
      diff = PerfDiffData.fromJson(Map<String, dynamic>.from(json['diff'] as Map));
    }
    ActionResult action;
    if (json['action'] is Map) {
      action = ActionResult.fromJson(Map<String, dynamic>.from(json['action'] as Map));
    } else {
      action = ActionResult(
        success: json['success'] == true || json['ok'] == true,
        driver: 'legacy',
        detail: json,
      );
    }
    return TapLegacyData(
      legacy: json['legacy'] != false,
      action: action,
      diff: diff,
      sessionId: json['sessionId'] as String?,
      warning: json['warning'] as String?,
    );
  }
}
