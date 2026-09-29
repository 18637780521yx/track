import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';

import '../event/event_models.dart';
import '../tracker_config.dart';
import '../utils/log.dart';
import 'result.dart';

typedef DioBodyBuilder = Object? Function(List<TrackEvent> events);

/// 创建基于 Dio 的事件上传函数。
///
/// 重试和压缩由内置的 Dio 拦截器完成，调用方无需关心。
EventUploader createDioEventUploader({
  required String url,
  Map<String, dynamic>? headers,
  DioBodyBuilder? bodyBuilder,
  TrackerConfig config = const TrackerConfig(),
}) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 30),
  ));

  if (config.compressRequest) {
    dio.interceptors.add(_GzipInterceptor());
  }
  dio.interceptors.add(_RetryInterceptor(
    dio: dio,
    maxRetryCount: config.maxRetryCount,
    backoffBase: config.retryBackoffBase,
    backoffMax: config.retryBackoffMax,
  ));

  final buildBody = bodyBuilder ??
      (events) => {
            'events': events.map((e) => e.toJson()).toList(),
          };

  return (List<TrackEvent> events) async {
    try {
      await dio.post<Object?>(
        url,
        data: buildBody(events),
        options: Options(headers: headers != null ? Map<String, dynamic>.from(headers) : null),
      );
      fastLog('upload ok, ${events.length} events');
      return const EventUploadResult.success();
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      fastLog('upload failed, code=$statusCode', error: e);

      if (statusCode != null &&
          statusCode >= 400 &&
          statusCode < 500 &&
          statusCode != 401 &&
          statusCode != 403 &&
          statusCode != 429) {
        return EventUploadResult.permanentFailure(
          statusCode: statusCode,
          message: 'http $statusCode',
        );
      }

      return EventUploadResult.retryableFailure(
        statusCode: statusCode,
        message: e.message,
      );
    } catch (e) {
      fastLog('upload error', error: e);
      return EventUploadResult.retryableFailure(message: e.toString());
    }
  };
}

// ---------------------------------------------------------------------------
// Dio Interceptors
// ---------------------------------------------------------------------------

/// Gzip 压缩拦截器：在 onRequest 阶段将 body 压缩为 gzip 字节流
class _GzipInterceptor extends Interceptor {
  static const _rawBodyKey = '_fast_track_raw_body';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final raw = options.data;
    if (raw == null) {
      handler.next(options);
      return;
    }

    try {
      options.extra[_rawBodyKey] = raw;
      final jsonBytes = utf8.encode(jsonEncode(raw));
      options.data = GZipEncoder().encode(jsonBytes);
      options.headers['Content-Type'] = 'application/json';
      options.headers['Content-Encoding'] = 'gzip';
    } catch (e) {
      fastLog('gzip compress failed, sending uncompressed', error: e);
      options.data = raw;
      options.extra.remove(_rawBodyKey);
    }
    handler.next(options);
  }
}

/// 重试拦截器：在 onError 阶段对可重试的失败做指数退避重试
///
/// 重试前会恢复原始 body（被 [_GzipInterceptor] 压缩前的），让下一次
/// 请求经过完整的拦截器链（重新压缩 + 重新发送）。
class _RetryInterceptor extends Interceptor {
  final Dio dio;
  final int maxRetryCount;
  final Duration backoffBase;
  final Duration backoffMax;

  static const _retryCountKey = '_fast_track_retry_count';

  _RetryInterceptor({
    required this.dio,
    required this.maxRetryCount,
    required this.backoffBase,
    required this.backoffMax,
  });

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (!_shouldRetry(err)) {
      handler.next(err);
      return;
    }

    final currentRetry = err.requestOptions.extra[_retryCountKey] as int? ?? 0;
    if (currentRetry >= maxRetryCount) {
      handler.next(err);
      return;
    }

    final backoff = _calcBackoff(currentRetry, err.response);
    fastLog(
      'retry ${currentRetry + 1}/$maxRetryCount, '
      'code=${err.response?.statusCode}, '
      'backoff=${backoff.inMilliseconds}ms',
      debug: true,
    );
    await Future<void>.delayed(backoff);

    final opts = err.requestOptions;
    opts.extra[_retryCountKey] = currentRetry + 1;

    // 恢复原始 body，让 GzipInterceptor 重新压缩
    final rawBody = opts.extra[_GzipInterceptor._rawBodyKey];
    if (rawBody != null) {
      opts.data = rawBody;
      opts.headers.remove('Content-Encoding');
      opts.extra.remove(_GzipInterceptor._rawBodyKey);
    }

    try {
      final response = await dio.fetch(opts);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.reject(e);
    }
  }

  bool _shouldRetry(DioException err) {
    if (err.type == DioExceptionType.cancel) return false;
    if (err.type != DioExceptionType.badResponse) return true;

    final status = err.response?.statusCode ?? 0;
    return status == 429 || status == 401 || status == 403 || status >= 500;
  }

  Duration _calcBackoff(int retryCount, Response? response) {
    if (response?.statusCode == 429) {
      final header = response?.headers.value('retry-after');
      if (header != null) {
        final seconds = int.tryParse(header);
        if (seconds != null) return Duration(seconds: seconds);
      }
    }
    final factor = 1 << retryCount;
    var d = backoffBase * factor;
    if (d > backoffMax) d = backoffMax;
    return d;
  }
}
