import 'dart:convert';
import 'package:objectbox/objectbox.dart';

/// 单条事件
///
/// 每条事件带有唯一 [id]（上报字段名为 `event_id`），便于服务端按 ID 去重（重试幂等）。
/// 与 Mixpanel 的 `$insert_id`、Segment/RudderStack 的 `messageId` 用途一致。
@Entity()
class TrackEvent {
  /// ObjectBox 内部 ID（自增）
  @Id()
  int objectBoxId;

  /// 唯一 ID，重试时不变；服务端可据此去重实现 exactly-once
  @Unique()
  String id;

  String name;

  /// JSON 序列化存储（ObjectBox 持久化字段）
  String propertiesJson;

  /// JSON 序列化存储（ObjectBox 持久化字段）
  String commonPropertiesJson;

  String? distinctId;
  String? anonymousId;
  String sessionId;

  @Property(type: PropertyType.date)
  DateTime timestamp;

  TrackEvent({
    this.objectBoxId = 0,
    required this.id,
    required this.name,
    String? propertiesJson,
    String? commonPropertiesJson,
    required this.sessionId,
    required this.timestamp,
    this.distinctId,
    this.anonymousId,
  })  : propertiesJson = propertiesJson ?? '{}',
        commonPropertiesJson = commonPropertiesJson ?? '{}';

  /// 便捷构造函数：从 Map 创建
  factory TrackEvent.fromMaps({
    int objectBoxId = 0,
    required String id,
    required String name,
    required Map<String, dynamic> properties,
    required Map<String, dynamic> commonProperties,
    required String sessionId,
    required DateTime timestamp,
    String? distinctId,
    String? anonymousId,
  }) {
    return TrackEvent(
      objectBoxId: objectBoxId,
      id: id,
      name: name,
      propertiesJson: jsonEncode(properties),
      commonPropertiesJson: jsonEncode(commonProperties),
      sessionId: sessionId,
      timestamp: timestamp,
      distinctId: distinctId,
      anonymousId: anonymousId,
    );
  }

  /// 获取 properties（解析 JSON）
  Map<String, dynamic> get properties {
    try {
      final decoded = jsonDecode(propertiesJson);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (e) {
      return {};
    }
  }

  /// 获取 commonProperties（解析 JSON）
  Map<String, dynamic> get commonProperties {
    try {
      final decoded = jsonDecode(commonPropertiesJson);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (e) {
      return {};
    }
  }

  factory TrackEvent.fromJson(Map<String, dynamic> json) {
    return TrackEvent.fromMaps(
      id: json['event_id'] as String? ?? json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      properties: (json['properties'] as Map?)?.cast<String, dynamic>() ?? {},
      commonProperties: (json['common_properties'] as Map?)?.cast<String, dynamic>() ?? {},
      distinctId: json['distinct_id'] as String?,
      anonymousId: json['anonymous_id'] as String?,
      sessionId: json['session_id'] as String? ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    );
  }

  /// 转为上报 JSON（直接使用 raw JSON 字段，避免 getter 的 try-catch 开销）
  Map<String, dynamic> toJson() {
    return {
      'event_id': id,
      'name': name,
      'properties': jsonDecode(propertiesJson),
      'common_properties': jsonDecode(commonPropertiesJson),
      'distinct_id': distinctId,
      'anonymous_id': anonymousId,
      'session_id': sessionId,
      'timestamp': timestamp.toUtc().toIso8601String(),
    };
  }

  String toJsonString() => jsonEncode(toJson());
}

/// Session 信息
class SessionInfo {
  final String id;
  final DateTime lastActiveAt;

  SessionInfo({
    required this.id,
    required this.lastActiveAt,
  });

  SessionInfo copyWith({DateTime? lastActiveAt}) {
    return SessionInfo(
      id: id,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'last_active_at': lastActiveAt.toIso8601String(),
    };
  }

  static SessionInfo? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final lastActive = DateTime.tryParse(json['last_active_at'] as String? ?? '');
    if (lastActive == null) return null;
    return SessionInfo(
      id: json['id'] as String? ?? '',
      lastActiveAt: lastActive,
    );
  }
}
