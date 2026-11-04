import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';

import '../network/network_capture.dart';

/// 性能检测统一出口：只走 [FastTracker] 埋点（复用 FastTrack 会话）。
///
/// 不再写入 SessionJournal / 本地 JSON·HTML 报告。
class FastTrackMcpDetectSink {
  FastTrackMcpDetectSink._();

  /// 质量/实时信号 → `perf_<type>` 埋点。
  static void alert({
    required String type,
    required String action,
    required String message,
    Object? value,
    String? routeHint,
  }) {
    final route = (routeHint != null && routeHint.isNotEmpty)
        ? routeHint
        : FastTrackMcpNetwork.currentRoute();
    final props = <String, dynamic>{
      'action': action,
      'message': message,
      if (route != null && route.isNotEmpty) 'route': route,
      if (value is Map<String, dynamic>) ...value,
      if (value != null && value is! Map<String, dynamic>) 'value': value,
    };
    final name = type.startsWith('perf_') ? type : 'perf_$type';
    unawaited(track(name, properties: props));
  }

  /// 写入 FastTrack 队列；[flush] 为 true 时立刻尝试上传。
  static Future<void> track(
    String name, {
    Map<String, dynamic> properties = const {},
    bool flush = false,
  }) async {
    try {
      await FastTracker.track(name, properties: properties);
      if (flush) {
        await FastTracker.tracker.flush();
      }
    } catch (e) {
      debugPrint('[ftm] track failed: $e');
    }
  }
}
