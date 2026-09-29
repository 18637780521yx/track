import 'dart:convert';

import 'package:fast_tools/fast_tools.dart';

import '../event/event_models.dart';
import 'log.dart';

/// fast_track 内部使用的存储封装，当前基于 SpUtils。
/// 若未来要切换为其它存储（如加密存储、本地文件），只需要修改此文件。
class Storage {
  static const _prefsKeyEvents = 'fast_track_events';
  static const _prefsKeyCommon = 'fast_track_common';
  static const _prefsKeySession = 'fast_track_session';
  static const _prefsKeyFirstOpen = 'fast_track_first_open';
  static const _prefsKeyLastActiveDate = 'fast_track_last_active_date';
  static const _prefsKeyDistinctId = 'fast_track_distinct_id';
  static const _prefsKeyAnonymousId = 'fast_track_anonymous_id';
  static const _prefsKeyOptOut = 'fast_track_opt_out';

  /// 加载事件列表
  static List<TrackEvent> loadEvents() {
    final eventsJson = SpUtils.getStringList(_prefsKeyEvents);
    final result = <TrackEvent>[];
    for (final e in eventsJson) {
      try {
        final map = jsonDecode(e) as Map<String, dynamic>;
        result.add(TrackEvent.fromJson(map));
      } catch (err) {
        fastLog('loadEvents skip broken entry', error: err);
      }
    }
    return result;
  }

  /// 持久化事件列表
  static Future<void> saveEvents(List<TrackEvent> events) async {
    final list = events.map((e) => jsonEncode(e.toJson())).toList(growable: false);
    SpUtils.setStringList(_prefsKeyEvents, list);
  }

  /// 加载公共属性
  static Map<String, dynamic> loadCommonProperties() {
    final commonJson = SpUtils.getString(_prefsKeyCommon);
    if (commonJson.isEmpty) return {};
    try {
      final map = jsonDecode(commonJson) as Map<String, dynamic>;
      return map;
    } catch (err) {
      fastLog('loadCommonProperties parse error', error: err);
      return {};
    }
  }

  /// 持久化公共属性
  static Future<void> saveCommonProperties(Map<String, dynamic> props) async {
    SpUtils.setString(_prefsKeyCommon, jsonEncode(props));
  }

  /// 加载 Session
  static SessionInfo? loadSession() {
    final sessionJson = SpUtils.getString(_prefsKeySession);
    if (sessionJson.isEmpty) return null;
    try {
      final map = jsonDecode(sessionJson) as Map<String, dynamic>;
      return SessionInfo.fromJson(map);
    } catch (err) {
      fastLog('loadSession parse error', error: err);
      return null;
    }
  }

  /// 持久化 Session
  static Future<void> saveSession(SessionInfo? session) async {
    SpUtils.setString(_prefsKeySession, jsonEncode(session?.toJson()));
  }

  /// 是否已记录过首次启动
  static bool get firstOpenFlag => SpUtils.getBool(_prefsKeyFirstOpen);

  /// 标记已记录首次启动
  static void setFirstOpenFlag(bool value) => SpUtils.setBool(_prefsKeyFirstOpen, value);

  /// 上次日活日期（格式 yyyy-M-d）
  static String? getLastActiveDate() {
    final s = SpUtils.getString(_prefsKeyLastActiveDate);
    return s.isEmpty ? null : s;
  }

  /// 保存上次日活日期
  static void setLastActiveDate(String date) => SpUtils.setString(_prefsKeyLastActiveDate, date);

  // --- 用户身份 ---

  static String? getDistinctId() {
    final s = SpUtils.getString(_prefsKeyDistinctId);
    return s.isEmpty ? null : s;
  }

  static void setDistinctId(String? id) {
    if (id == null || id.isEmpty) {
      SpUtils.remove(_prefsKeyDistinctId);
    } else {
      SpUtils.setString(_prefsKeyDistinctId, id);
    }
  }

  static String? getAnonymousId() {
    final s = SpUtils.getString(_prefsKeyAnonymousId);
    return s.isEmpty ? null : s;
  }

  static void setAnonymousId(String id) => SpUtils.setString(_prefsKeyAnonymousId, id);

  // --- 隐私合规 ---

  static bool get optOut => SpUtils.getBool(_prefsKeyOptOut);

  static void setOptOut(bool value) => SpUtils.setBool(_prefsKeyOptOut, value);
}
