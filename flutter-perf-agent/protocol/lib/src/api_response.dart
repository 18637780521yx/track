import 'api_codes.dart';

/// Unified envelope: `{ "code": 0, "data": ..., "msg": "ok" }`.
class ApiResponse<T> {
  const ApiResponse({
    required this.code,
    this.data,
    this.msg = 'ok',
  });

  final int code;
  final T? data;
  final String msg;

  bool get isOk => code == ApiCodes.ok;

  static ApiResponse<T> ok<T>(T? data, {String msg = 'ok'}) =>
      ApiResponse<T>(code: ApiCodes.ok, data: data, msg: msg);

  static ApiResponse<T> fail<T>(
    int code,
    String msg, {
    T? data,
  }) =>
      ApiResponse<T>(code: code, data: data, msg: msg);

  Map<String, dynamic> toJson([Object? Function(T value)? encodeData]) {
    Object? encoded;
    if (data != null) {
      encoded = encodeData != null ? encodeData(data as T) : _defaultEncode(data);
    }
    return {
      'code': code,
      'data': encoded,
      'msg': msg,
    };
  }

  static ApiResponse<T> fromJson<T>(
    Map<String, dynamic> json, {
    T? Function(Object? raw)? decodeData,
  }) {
    final code = (json['code'] as num?)?.toInt() ??
        (json['ok'] == true ? ApiCodes.ok : ApiCodes.internal);
    final msg = json['msg'] as String? ??
        json['error'] as String? ??
        (code == ApiCodes.ok ? 'ok' : 'error');
    final raw = json.containsKey('data') ? json['data'] : null;
    T? data;
    if (decodeData != null) {
      data = decodeData(raw);
    } else if (raw is T) {
      data = raw;
    } else if (raw == null) {
      data = null;
    }
    return ApiResponse<T>(code: code, data: data, msg: msg);
  }

  /// Parse unknown map; keeps [data] as dynamic Map/List when present.
  static ApiResponse<dynamic> parse(Map<String, dynamic> json) {
    return fromJson<dynamic>(
      json,
      decodeData: (raw) => raw,
    );
  }

  static Object? _defaultEncode(Object? value) {
    if (value == null) return null;
    if (value is Map || value is List || value is String || value is num || value is bool) {
      return value;
    }
    try {
      // ignore: avoid_dynamic_calls
      return (value as dynamic).toJson();
    } catch (_) {
      return value.toString();
    }
  }
}
