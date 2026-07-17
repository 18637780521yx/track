/// flush 结果回调
typedef FlushResultCallback = void Function(FlushResult result);

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

class TrackerConfig {
  /// **单次请求最多发多少条**：每次 flush 时，从队列里最多取 [maxBatchSize] 条打成一批、发一次 HTTP 请求；同时「队列长度 ≥ maxBatchSize」会触发一次自动 flush（满批即发）。与神策 flush_bulkSize 一致，默认 100。
  final int maxBatchSize;

  /// 失败后最大重试次数
  final int maxRetryCount;

  /// 批量发送最小间隔（默认 15 秒）
  final Duration flushInterval;

  /// **队列最多存多少条**：ObjectBox 持久化的总条数上限。超过时从队头丢最老事件（会丢事件），保证队列有界、不占满磁盘。默认 10000 条（约 6-17 MB）。
  /// 有界队列无法保证不丢：队列满时必然丢最老事件；若要不丢只能改为无界队列（受存储限制）或队列满时背压（track 等待），需在「可能占满磁盘」或「可能阻塞」之间权衡。
  final int maxCachedEvents;

  /// Session 过期时间
  final Duration sessionTimeout;

  /// 重试退避基础间隔
  final Duration retryBackoffBase;

  /// 重试退避最大间隔
  final Duration retryBackoffMax;

  /// 重试用尽后的冷却时间，此期间不再次发送本批，冷却结束后下次 flush 再试（不丢事件）
  final Duration retryCoolOffDuration;

  /// 是否输出调试日志（会使用 debugPrint）
  final bool enableDebugLog;

  /// 是否对请求 body 做 gzip 压缩（需后端支持 Content-Encoding: gzip 解压），默认关闭
  final bool compressRequest;

  /// Debug 干跑模式：为 true 时只记录日志不实际上传，便于开发阶段验证埋点
  final bool dryRun;

  /// 是否在 flush 前检查网络连通性，无网时跳过本次 flush（事件保留在队列中）
  final bool checkNetworkBeforeFlush;

  /// flush 结果回调，可用于监控上传成功/失败统计
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
    this.checkNetworkBeforeFlush = true,
    this.onFlushResult,
  });
}
