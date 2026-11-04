import 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';

import '../network/network_capture.dart';
import '../session/session_journal.dart';

/// 性能检测上报：调试会话写入 [SessionJournal]，线上走 [FastTracker]。
class FastTrackMcpDetectSink {
  FastTrackMcpDetectSink._();

  /// 会话进行中时挂一条实时告警。无会话则忽略（调试路径）。
  static void alert({
    required String type,
    required String action,
    required String message,
    Object? value,
    String? routeHint,
  }) {
    final journal = SessionJournal.instance;
    if (!journal.isActive) return;
    final route = (routeHint != null && routeHint.isNotEmpty)
        ? routeHint
        : FastTrackMcpNetwork.currentRoute();
    journal.appendRealtimeAlert(
      AlertItem(
        type: type,
        stepId: '',
        action: action,
        message: message,
        value: value,
        at: DateTime.now().toIso8601String(),
      ),
      routeHint: route,
    );
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
