import '../event/event_models.dart';

/// 上报结果类型，用于区分是否需要重试等策略。
class EventUploadResult {
  final bool success;

  /// 是否建议保留事件稍后重试（5xx / 网络错误 → true，4xx 数据错误 → false）
  final bool shouldRetry;

  final int? statusCode;
  final String? message;

  const EventUploadResult({
    required this.success,
    required this.shouldRetry,
    this.statusCode,
    this.message,
  });

  const EventUploadResult.success()
      : success = true,
        shouldRetry = false,
        statusCode = null,
        message = null;

  const EventUploadResult.permanentFailure({
    this.statusCode,
    this.message,
  })  : success = false,
        shouldRetry = false;

  const EventUploadResult.retryableFailure({
    this.statusCode,
    this.message,
  })  : success = false,
        shouldRetry = true;
}

/// 事件上传函数签名，重试/压缩已在 Dio 层完成，调用方只需关心最终结果
typedef EventUploader = Future<EventUploadResult> Function(List<TrackEvent> events);
