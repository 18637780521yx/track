import 'package:flutter/foundation.dart';

import '../fast_tracker.dart';

/// [message] 为日志内容；[error] 为可选异常；[debug] 为 true 时仅当 config.enableDebugLog 时输出（直接读单例配置）
void fastLog(String message, {Object? error, bool debug = false}) {
  if (debug && !FastTracker.tracker.config.enableDebugLog) return;
  final ts = DateTime.now();
  final tsStr =
      '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}:${ts.second.toString().padLeft(2, '0')}.${ts.millisecond.toString().padLeft(3, '0')}';
  debugPrint('[$tsStr] [fast_track] $message ${error?.toString()}');
}
