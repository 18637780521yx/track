/// One HTTP request observed during a perf step.
///
/// Prefer full capture from FastTrackMcp HttpOverrides (headers + bodies).
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
    this.source = 'full',
    this.finalUrl,
    this.path,
    this.flags = const [],
  });

  final String url;
  final String method;
  final int statusCode;
  final int durationMs;
  final int responseBytes;
  final String startedAt;

  /// App route when the request was **started**.
  final String? route;

  final bool cancelled;
  final String? contentType;

  final Map<String, String>? requestHeaders;
  final String? requestBody;
  final bool requestBodyTruncated;
  final int? requestBytes;

  final Map<String, String>? responseHeaders;
  final String? responseBody;
  final bool responseBodyTruncated;

  final String? error;

  /// `full` = FastTrackMcp HttpCapture; `sleuth` = legacy timing-only.
  final String source;

  /// URL after redirects (if different from [url]).
  final String? finalUrl;

  /// Short path for timeline labels (`/api/v1/login`).
  final String? path;

  /// Quality tags: `slow` / `large` / `http_error` / `cancelled` / `client_error`.
  final List<String> flags;

  bool get hasPayload =>
      requestBody != null ||
      responseBody != null ||
      (requestHeaders != null && requestHeaders!.isNotEmpty) ||
      (responseHeaders != null && responseHeaders!.isNotEmpty);

  bool get isSlow => flags.contains('slow');
  bool get isLarge => flags.contains('large');
  bool get isHttpError => flags.contains('http_error');

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
        if (finalUrl != null && finalUrl != url) 'finalUrl': finalUrl,
        if (path != null && path!.isNotEmpty) 'path': path,
        if (flags.isNotEmpty) 'flags': flags,
      };

  factory NetworkRequest.fromJson(Map<String, dynamic> json) {
    final rawFlags = json['flags'];
    final flags = <String>[];
    if (rawFlags is List) {
      for (final f in rawFlags) {
        final s = f?.toString();
        if (s != null && s.isNotEmpty) flags.add(s);
      }
    }
    return NetworkRequest(
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
      source: json['source']?.toString() ?? 'full',
      finalUrl: json['finalUrl']?.toString(),
      path: json['path']?.toString(),
      flags: flags,
    );
  }

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
