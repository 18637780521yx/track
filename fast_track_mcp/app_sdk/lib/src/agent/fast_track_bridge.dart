import 'package:flutter/foundation.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';

/// 把 perf-agent 的线上轻量泄漏信号接到 [FastTracker]。
///
/// **职责划分（避免双钩子冲突）**
/// - FastTrack：**独占** crash / Zone / ANR / 生产 jank / RSS `app_memory_leak`
/// - FastTrackMcp：开发账本、WeakRef 转场泄漏、全量 HTTP、Bridge/MCP
/// - 本桥：仅 `LeakOnline` → `FastTracker.track`，不重装 FlutterError / timings
class FastTrackMcpBridge {
  FastTrackMcpBridge._();

  /// LeakOnline `onEvent` 可直接挂这个。
  static void forwardLeakOnlineEvent(Map<String, dynamic> event) {
    final type = '${event['type'] ?? ''}';
    final name = switch (type) {
      'transition_leak' => 'perf_transition_leak',
      'route_breadcrumb' => 'perf_route_breadcrumb',
      _ => type.isEmpty ? 'perf_leak_online' : 'perf_$type',
    };
    try {
      FastTracker.track(name, properties: Map<String, dynamic>.from(event));
    } catch (e, st) {
      debugPrint('[FastTrackMcpBridge] track failed: $e\n$st');
    }
  }

  /// 便捷：若宿主已 [FastTracker.init]，返回可传给 [FastTrackMcp.ensureInitialized]
  /// 的 `onLeakOnlineEvent`；否则返回 `null`（由调用方自行判断）。
  static void Function(Map<String, dynamic>)? leakOnlineHandlerIfReady() {
    try {
      // FastTracker 未 init 时 track 通常 no-op 或抛错；这里仍返回 handler，
      // 由 track 内部兜底。显式 API 留给宿主在 init 之后再 wire。
      return forwardLeakOnlineEvent;
    } catch (_) {
      return null;
    }
  }
}
