/// One HTTP request observed during a perf step.
///
/// Prefer full capture from PerfAgent HttpOverrides (headers + bodies).
class NetworkRequest {
  const NetworkRequest({
    required this.url,
    required this.method,
    required this.statusCode,
    required this.durationMs,
    required this.responseBytes,
    required this.startedAt,
    this.route,
    this.cancelled = false,
    this.contentType,
    this.requestHeaders,
    this.requestBody,
    this.requestBodyTruncated = false,
    this.requestBytes,
    this.responseHeaders,
    this.responseBody,
    this.responseBodyTruncated = false,
    this.error,
    this.source = 'sleuth',
  });

  final String url;
  final String method;
  final int statusCode;
  final int durationMs;
  final int responseBytes;
  final String startedAt;

  /// App route when the request was **started** (not when the step screenshot
  /// was taken). Login APIs stay tagged `/login` even if the step ends on home.
  final String? route;

  final bool cancelled;
  final String? contentType;

  /// Request headers (sensitive values may be redacted).
  final Map<String, String>? requestHeaders;

  /// Captured request body as UTF-8 text (or a `[binary …]` placeholder).
  final String? requestBody;
  final bool requestBodyTruncated;
  final int? requestBytes;

  /// Response headers.
  final Map<String, String>? responseHeaders;

  /// Captured response body as UTF-8 text (or a `[binary …]` placeholder).
  final String? responseBody;
  final bool responseBodyTruncated;

  final String? error;

  /// `full` = PerfAgent HttpCapture; `sleuth` = legacy timing-only.
  final String source;

  bool get hasPayload =>
      requestBody != null ||
      responseBody != null ||
      (requestHeaders != null && requestHeaders!.isNotEmpty) ||
      (responseHeaders != null && responseHeaders!.isNotEmpty);

  Map<String, dynamic> toJson() => {
        'url': url,
        'method': method,
        'statusCode': statusCode,
        'durationMs': durationMs,
        'responseBytes': responseBytes,
        'startedAt': startedAt,
        'source': source,
        if (route != null && route!.isNotEmpty) 'route': route,
        if (cancelled) 'cancelled': true,
        if (contentType != null) 'contentType': contentType,
        if (requestHeaders != null) 'requestHeaders': requestHeaders,
        if (requestBody != null) 'requestBody': requestBody,
        if (requestBodyTruncated) 'requestBodyTruncated': true,
        if (requestBytes != null) 'requestBytes': requestBytes,
        if (responseHeaders != null) 'responseHeaders': responseHeaders,
        if (responseBody != null) 'responseBody': responseBody,
        if (responseBodyTruncated) 'responseBodyTruncated': true,
        if (error != null) 'error': error,
      };

  factory NetworkRequest.fromJson(Map<String, dynamic> json) => NetworkRequest(
        url: json['url']?.toString() ?? '',
        method: json['method']?.toString() ?? 'GET',
        statusCode: (json['statusCode'] as num?)?.toInt() ?? -1,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        responseBytes: (json['responseBytes'] as num?)?.toInt() ?? 0,
        startedAt: json['startedAt']?.toString() ?? '',
        route: json['route']?.toString(),
        cancelled: json['cancelled'] == true,
        contentType: json['contentType']?.toString(),
        requestHeaders: _stringMap(json['requestHeaders']),
        requestBody: json['requestBody']?.toString(),
        requestBodyTruncated: json['requestBodyTruncated'] == true,
        requestBytes: (json['requestBytes'] as num?)?.toInt(),
        responseHeaders: _stringMap(json['responseHeaders']),
        responseBody: json['responseBody']?.toString(),
        responseBodyTruncated: json['responseBodyTruncated'] == true,
        error: json['error']?.toString(),
        source: json['source']?.toString() ?? 'sleuth',
      );

  static Map<String, String>? _stringMap(Object? raw) {
    if (raw is! Map) return null;
    return raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
  }
}

class NetworkRequestsData {
  const NetworkRequestsData({
    required this.requests,
    this.since,
  });

  final List<NetworkRequest> requests;
  final String? since;

  int get count => requests.length;

  Map<String, dynamic> toJson() => {
        'count': count,
        if (since != null) 'since': since,
        'requests': requests.map((r) => r.toJson()).toList(),
      };

  factory NetworkRequestsData.fromJson(Map<String, dynamic> json) {
    final list = <NetworkRequest>[];
    final raw = json['requests'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          list.add(NetworkRequest.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return NetworkRequestsData(
      requests: list,
      since: json['since'] as String?,
    );
  }
}
