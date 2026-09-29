import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'event_models.dart';
import '../utils/log.dart';

import 'objectbox.g.dart'; // 生成的代码

/// ObjectBox 存储管理器
class FastStorage {
  static Store? _store;
  static Box<TrackEvent>? _box;

  /// 初始化锁，防止并发初始化
  static bool _initializing = false;

  /// 初始化 ObjectBox
  ///
  /// 方案2：如果初始化失败，尝试删除损坏的数据库并重试
  /// 并发安全：使用 _initializing 标志防止重复初始化
  static Future<void> init() async {
    // 并发控制：如果已经初始化完成，直接返回
    if (_store != null) return;

    // 并发控制：如果正在初始化，等待完成
    if (_initializing) {
      // 简单的自旋等待（最多等待 5 秒）
      for (var i = 0; i < 50; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_store != null) return;
      }
      throw Exception('ObjectBox init timeout: another init is in progress');
    }

    _initializing = true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final storePath = p.join(dir.path, 'fast_track_objectbox');

      try {
        // 第一次尝试：正常初始化
        _store = await openStore(directory: storePath);
        _box = _store!.box<TrackEvent>();
        fastLog('ObjectBox initialized: ${_box!.count()} events', debug: true);
      } catch (e) {
        // 初始化失败，尝试删除损坏的数据库并重试
        fastLog('ObjectBox init failed, try delete and retry', error: e);

        try {
          final storeDir = Directory(storePath);
          if (storeDir.existsSync()) {
            storeDir.deleteSync(recursive: true);
            fastLog('Deleted corrupted ObjectBox directory', debug: true);
          }

          // 第二次尝试：删除后重新初始化
          _store = await openStore(directory: storePath);
          _box = _store!.box<TrackEvent>();
          fastLog('ObjectBox re-initialized successfully: ${_box!.count()} events', debug: true);
        } catch (e2) {
          // 仍然失败，记录错误并抛出
          fastLog('ObjectBox re-init failed after delete', error: e2);
          rethrow;
        }
      }
    } finally {
      _initializing = false;
    }
  }

  /// 追加单个事件（增量写入）
  static Future<void> appendEvent(TrackEvent event) async {
    try {
      _box!.put(event);
    } catch (e) {
      fastLog('ObjectBox appendEvent failed', error: e);
      rethrow;
    }
  }

  /// 批量追加事件
  static Future<void> appendEvents(List<TrackEvent> events) async {
    if (events.isEmpty) return;

    try {
      _box!.putMany(events);
    } catch (e) {
      fastLog('ObjectBox appendEvents failed', error: e);
      rethrow;
    }
  }

  /// 加载事件（按时间戳排序，可指定 limit）
  static Future<List<TrackEvent>> loadEvents({int? limit}) async {
    try {
      final query = _box!.query().order(TrackEvent_.timestamp).build();

      if (limit != null) query.limit = limit;
      final events = query.find();
      query.close();

      fastLog('ObjectBox loaded ${events.length} events', debug: true);
      return events;
    } catch (e) {
      fastLog('ObjectBox loadEvents failed', error: e);
      return [];
    }
  }

  /// 按 ID 批量删除事件
  static Future<void> deleteEvents(List<String> eventIds) async {
    if (eventIds.isEmpty) return;

    try {
      final query = _box!.query(TrackEvent_.id.oneOf(eventIds)).build();
      final count = query.remove();
      query.close();

      fastLog('ObjectBox deleted $count events', debug: true);
    } catch (e) {
      fastLog('ObjectBox deleteEvents failed', error: e);
      rethrow;
    }
  }

  /// 删除最老的 N 条事件（按时间戳排序）
  static Future<void> deleteOldestEvents(int count) async {
    if (count <= 0) return;

    try {
      // 查询最老的 N 条事件（按时间戳升序）
      final query = _box!.query().order(TrackEvent_.timestamp).build();
      query.limit = count;

      final oldestEvents = query.find();
      query.close();

      if (oldestEvents.isEmpty) return;

      // 批量删除
      final objectBoxIds = oldestEvents.map((e) => e.objectBoxId).toList();
      _box!.removeMany(objectBoxIds);

      fastLog('ObjectBox deleted ${objectBoxIds.length} oldest events', debug: true);
    } catch (e) {
      fastLog('ObjectBox deleteOldestEvents failed', error: e);
      rethrow;
    }
  }

  /// 获取事件数量
  static int getEventCount() {
    return _box?.count() ?? 0;
  }

  /// 清空所有事件
  static Future<void> clear() async {
    try {
      _box!.removeAll();
      fastLog('ObjectBox cleared', debug: true);
    } catch (e) {
      fastLog('ObjectBox clear failed', error: e);
      rethrow;
    }
  }

  /// 关闭 ObjectBox
  static void close() {
    _store?.close();
    _store = null;
    _box = null;
    fastLog('ObjectBox closed', debug: true);
  }
}
