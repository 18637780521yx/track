/// flush 结果回调
typedef FlushResultCallback = void Function(FlushResult result);

/// 运行环境：对齐 Adjust 的 sandbox / production 隔离
enum TrackEnvironment {
  sandbox,
  production,
}

extension TrackEnvironmentX on TrackEnvironment {
  String get wireValue => switch (this) {
        TrackEnvironment.sandbox => 'sandbox',
        TrackEnvironment.production => 'production',
      };
}

/// flush 结果
class FlushResult {
  final int sentCount;
  final int failedCount;
  final int droppedCount;
  final String? lastError;

  const FlushResult({
    this.sentCount = 0,
    this.failedCount = 0,
    this.droppedCount = 0,
    this.lastError,
  });
}

/// FastTrack 仅负责 track / 会话 / 批上报。检测钩子在 `fast_track_mcp` App SDK。
class TrackerConfig {
  /// **单次请求最多发多少条**
  final int maxBatchSize;

  /// 失败后最大重试次数
  final int maxRetryCount;

  /// 定时上传周期（默认 15 秒）；达到批量阈值或显式 flush 可提前上传。
  final Duration flushInterval;

  /// **队列最多存多少条**
  final int maxCachedEvents;

  /// Session 过期时间
  final Duration sessionTimeout;

  /// 重试退避基础间隔
  final Duration retryBackoffBase;

  /// 重试退避最大间隔
  final Duration retryBackoffMax;

  /// 重试用尽后的冷却时间
  final Duration retryCoolOffDuration;

  /// 是否输出调试日志
  final bool enableDebugLog;

  /// 是否对请求 body 做 gzip 压缩
  final bool compressRequest;

  /// Debug 干跑模式
  final bool dryRun;

  /// 运行环境：sandbox / production
  final TrackEnvironment? environment;

  /// 是否在 flush 前检查网络连通性
  final bool checkNetworkBeforeFlush;

  /// flush 结果回调
  final FlushResultCallback? onFlushResult;

  const TrackerConfig({
    this.maxBatchSize = 100,
    this.maxRetryCount = 5,
    this.flushInterval = const Duration(seconds: 15),
    this.maxCachedEvents = 10000,
    this.sessionTimeout = const Duration(minutes: 30),
    this.retryBackoffBase = const Duration(seconds: 2),
    this.retryBackoffMax = const Duration(minutes: 1),
    this.retryCoolOffDuration = const Duration(minutes: 30),
    this.enableDebugLog = false,
    this.compressRequest = false,
    this.dryRun = false,
    this.environment,
    this.checkNetworkBeforeFlush = true,
    this.onFlushResult,
  });
}
