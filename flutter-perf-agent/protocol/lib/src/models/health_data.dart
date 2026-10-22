import 'sleuth_data.dart';

class HealthData {
  const HealthData({
    required this.bridge,
    required this.version,
    this.sessionId,
    this.testName,
    this.vmServiceUri,
    this.uiDriver = 'flutter_skill',
    this.sleuth,
    this.mode,
    this.lifecycle,
    this.lifecycleForeground = false,
  });

  final String bridge;
  final String version;
  final String? sessionId;
  final String? testName;
  final String? vmServiceUri;
  final String uiDriver;
  final SleuthDiagnoseData? sleuth;
  final String? mode;

  /// Latest App lifecycle: `{kind, label, at, route?}` —
  /// `cold_start` / `foreground` / `background`.
  final Map<String, dynamic>? lifecycle;

  /// True when [lifecycle] kind is `cold_start` or `foreground`.
  final bool lifecycleForeground;

  Map<String, dynamic> toJson() => {
        'bridge': bridge,
        'version': version,
        'sessionId': sessionId,
        'testName': testName,
        'vmServiceUri': vmServiceUri,
        'uiDriver': uiDriver,
        if (sleuth != null) 'sleuth': sleuth!.toJson(),
        'mode': mode,
        if (lifecycle != null) 'lifecycle': lifecycle,
        'lifecycleForeground': lifecycleForeground,
      };

  factory HealthData.fromJson(Map<String, dynamic> json) {
    SleuthDiagnoseData? sleuth;
    final raw = json['sleuth'];
    if (raw is Map) {
      sleuth = SleuthDiagnoseData.fromJson(Map<String, dynamic>.from(raw));
    }
    Map<String, dynamic>? lifecycle;
    final lifeRaw = json['lifecycle'];
    if (lifeRaw is Map) {
      lifecycle = Map<String, dynamic>.from(lifeRaw);
    }
    return HealthData(
      bridge: json['bridge'] as String? ?? 'flutter-perf-agent',
      version: json['version'] as String? ?? '0.6.0',
      sessionId: json['sessionId'] as String?,
      testName: json['testName'] as String?,
      vmServiceUri: json['vmServiceUri'] as String?,
      uiDriver: json['uiDriver'] as String? ?? 'flutter_skill',
      sleuth: sleuth,
      mode: json['mode'] as String?,
      lifecycle: lifecycle,
      lifecycleForeground: json['lifecycleForeground'] == true,
    );
  }
}
