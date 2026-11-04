/// 稳定性事件名。字符串与 flutter_fast_track 的 FastTrackEventName 对齐。
class FastTrackMcpEventName {
  FastTrackMcpEventName._();

  static const appCrash = 'app_crash';
  static const appError = 'app_error';
  static const appAnr = 'app_anr';
  static const appJank = 'app_jank';
  static const appMemoryLeak = 'app_memory_leak';
}
