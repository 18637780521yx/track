import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:sleuth/sleuth.dart';

/// Ring buffer of full HTTP captures (headers + bodies).
class PerfNetworkStore {
  PerfNetworkStore._();
  static final PerfNetworkStore instance = PerfNetworkStore._();

  static const int defaultCapacity = 200;
  static const int defaultMaxBodyBytes = 64 * 1024;

  final Queue<NetworkRequest> _records = Queue<NetworkRequest>();
  int capacity = defaultCapacity;
  int maxBodyBytes = defaultMaxBodyBytes;

  List<NetworkRequest> get records => List.unmodifiable(_records);

  void clear() => _records.clear();

  void add(NetworkRequest record) {
    _records.add(record);
    while (_records.length > capacity) {
      _records.removeFirst();
    }
  }
}

/// App route stamp + HttpOverrides installer.
///
/// Capture proxy follows Sleuth's `SleuthHttpOverrides` shape (chaining +
/// subscription that owns terminal events) and additionally records
/// request/response headers and bodies.
class PerfNetworkCapture {
  static PerfHttpOverrides? _overrides;

  static List<String> _excludeUrlSubstrings = const [
    '127.0.0.1:19288',
    '/sleuth/',
    'flutter-perf-agent',
  ];
  static List<String> _allowedHosts = const [];
  static bool _httpsOnly = false;
  static bool _allowHttpLoopback = true;
  static bool _redactSensitiveHeaders = true;

  static bool get isInstalled =>
      _overrides != null && identical(HttpOverrides.current, _overrides);

  /// Host whitelist in effect (`host` or `host:port`). Empty = all hosts.
  static List<String> get allowedHosts => _allowedHosts;

  /// When true, only `https` (plus loopback `http` if [allowHttpLoopback]).
  static bool get httpsOnly => _httpsOnly;

  static bool get allowHttpLoopback => _allowHttpLoopback;

  /// Optional app-specific route resolver (e.g. `() => Get.currentRoute`).
  static String? Function()? routeProvider;

  static String? currentRoute() {
    try {
      final custom = routeProvider?.call();
      if (custom != null && custom.trim().isNotEmpty) return custom.trim();
    } catch (_) {}
    try {
      final hist = Sleuth.routeHistory;
      if (hist != null && hist.isNotEmpty) {
        final name = hist.last.routeName;
        if (name.isNotEmpty) return name;
      }
    } catch (_) {}
    return null;
  }

  /// Whether [url] passes exclude / scheme / host whitelist filters.
  static bool shouldCapture(Uri url) {
    final s = url.toString();
    for (final p in _excludeUrlSubstrings) {
      if (p.isNotEmpty && s.contains(p)) return false;
    }
    if (!_schemeAllowed(url)) return false;
    if (!_hostAllowed(url)) return false;
    return true;
  }

  static bool _schemeAllowed(Uri url) {
    if (!_httpsOnly) return true;
    final scheme = url.scheme.toLowerCase();
    if (scheme == 'https') return true;
    if (_allowHttpLoopback && scheme == 'http' && _isLoopbackHost(url.host)) {
      return true;
    }
    return false;
  }

  static bool _isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '::1' ||
        h == '0:0:0:0:0:0:0:1' ||
        h == '10.0.2.2'; // Android emulator → host machine
  }

  /// Match `host` or `host:port` entries (case-insensitive).
  static bool _hostAllowed(Uri url) {
    if (_allowedHosts.isEmpty) return true;
    final host = url.host.toLowerCase();
    if (host.isEmpty) return false;
    final withPort = '$host:${url.port}';
    for (final raw in _allowedHosts) {
      final e = raw.trim().toLowerCase();
      if (e.isEmpty) continue;
      if (e == host || e == withPort) return true;
      // Whitelist `api.example.com` matches any port on that host.
      if (!e.contains(':') && e == host) return true;
    }
    return false;
  }

  /// Build `host` / `host:port` entries from absolute API base URLs.
  static List<String> hostsFromBaseUrls(Iterable<String> baseUrls) {
    final out = <String>{};
    for (final raw in baseUrls) {
      final u = Uri.tryParse(raw.trim());
      if (u == null || u.host.isEmpty) continue;
      final host = u.host.toLowerCase();
      out.add(u.hasPort ? '$host:${u.port}' : host);
      if (host == '127.0.0.1' && u.hasPort) {
        out.add('localhost:${u.port}');
      } else if (host == 'localhost' && u.hasPort) {
        out.add('127.0.0.1:${u.port}');
      }
    }
    return out.toList();
  }

  /// Install (or re-chain) as [HttpOverrides.global]. Prefer with Sleuth
  /// `enableNetworkMonitoring: false` so we own the slot alone.
  ///
  /// [allowedHosts]: `host` or `host:port`. Empty / omitted keeps prior list
  /// (default empty = capture all hosts after excludes).
  /// [httpsOnly]: only HTTPS; loopback HTTP still allowed when
  /// [allowHttpLoopback] is true (local demo API).
  static void install({
    int maxBodyBytes = PerfNetworkStore.defaultMaxBodyBytes,
    int capacity = PerfNetworkStore.defaultCapacity,
    List<String>? excludeUrlSubstrings,
    List<String>? allowedHosts,
    bool? httpsOnly,
    bool? allowHttpLoopback,
    bool? redactSensitiveHeaders,
  }) {
    if (kReleaseMode) return;
    PerfNetworkStore.instance.maxBodyBytes = maxBodyBytes;
    PerfNetworkStore.instance.capacity = capacity;
    if (excludeUrlSubstrings != null) {
      _excludeUrlSubstrings = List.unmodifiable(excludeUrlSubstrings);
    }
    if (allowedHosts != null) {
      _allowedHosts = List.unmodifiable(
        allowedHosts.map((e) => e.trim()).where((e) => e.isNotEmpty),
      );
    }
    if (httpsOnly != null) _httpsOnly = httpsOnly;
    if (allowHttpLoopback != null) _allowHttpLoopback = allowHttpLoopback;
    if (redactSensitiveHeaders != null) {
      _redactSensitiveHeaders = redactSensitiveHeaders;
    }
    if (identical(HttpOverrides.current, _overrides) && _overrides != null) {
      return;
    }
    _overrides = PerfHttpOverrides(
      redactSensitiveHeaders: _redactSensitiveHeaders,
    );
    HttpOverrides.global = _overrides;
    debugPrint(
      '[PerfAgent] HTTP full capture installed '
      '(hosts=${_allowedHosts.isEmpty ? "ALL" : _allowedHosts.join(",")}; '
      'httpsOnly=$_httpsOnly)',
    );
  }

  /// Install now + a few delayed retries (hot restart / late overrides).
  /// Options are stored and reused by each retry.
  static void installDeferred({
    Duration delay = const Duration(milliseconds: 400),
    int maxBodyBytes = PerfNetworkStore.defaultMaxBodyBytes,
    int capacity = PerfNetworkStore.defaultCapacity,
    List<String>? excludeUrlSubstrings,
    List<String>? allowedHosts,
    bool? httpsOnly,
    bool? allowHttpLoopback,
    bool? redactSensitiveHeaders,
  }) {
    if (kReleaseMode) return;
    void go() => install(
          maxBodyBytes: maxBodyBytes,
          capacity: capacity,
          excludeUrlSubstrings: excludeUrlSubstrings,
          allowedHosts: allowedHosts,
          httpsOnly: httpsOnly,
          allowHttpLoopback: allowHttpLoopback,
          redactSensitiveHeaders: redactSensitiveHeaders,
        );
    go();
    Future<void>.delayed(delay, go);
    Future<void>.delayed(const Duration(milliseconds: 1200), go);
    Future<void>.delayed(const Duration(milliseconds: 2500), go);
  }
}

/// Chaining [HttpOverrides] — same pattern as Sleuth's monitor, plus bodies.
///
/// Host / scheme filters live on [PerfNetworkCapture] (see [shouldCapture]).
class PerfHttpOverrides extends HttpOverrides {
  PerfHttpOverrides({
    this.redactSensitiveHeaders = true,
  }) : _previous = HttpOverrides.current;

  final bool redactSensitiveHeaders;
  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _CaptureHttpClient(
      inner,
      redactSensitiveHeaders: redactSensitiveHeaders,
    );
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _previous?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}

class _CaptureHttpClient implements HttpClient {
  _CaptureHttpClient(
    this._inner, {
    required this.redactSensitiveHeaders,
  });

  final HttpClient _inner;
  final bool redactSensitiveHeaders;

  bool _skip(Uri url) => !PerfNetworkCapture.shouldCapture(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (_skip(url)) return _inner.openUrl(method, url);
    final started = DateTime.now();
    final route = PerfNetworkCapture.currentRoute();
    try {
      final req = await _inner.openUrl(method, url);
      return _CaptureRequest(
        req,
        method: method.toUpperCase(),
        url: url.toString(),
        startedAt: started,
        route: route,
        redactSensitiveHeaders: redactSensitiveHeaders,
      );
    } catch (e) {
      _emitFailure(
        method: method.toUpperCase(),
        url: url.toString(),
        startedAt: started,
        route: route,
        error: e,
      );
      rethrow;
    }
  }

  static void _emitFailure({
    required String method,
    required String url,
    required DateTime startedAt,
    required String? route,
    required Object error,
  }) {
    try {
      PerfNetworkStore.instance.add(
        NetworkRequest(
          url: url,
          method: method,
          statusCode: -1,
          durationMs: DateTime.now().difference(startedAt).inMilliseconds,
          responseBytes: 0,
          startedAt: startedAt.toIso8601String(),
          route: route,
          error: error.toString(),
          source: 'full',
        ),
      );
    } catch (_) {}
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) {
    final scheme = port == 443 ? 'https' : 'http';
    return openUrl(
      method,
      Uri(scheme: scheme, host: host, port: port, path: path),
    );
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        f,
  ) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? f,
  ) =>
      _inner.connectionFactory = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials cred,
  ) =>
      _inner.addProxyCredentials(host, port, realm, cred);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

class _CaptureRequest implements HttpClientRequest {
  _CaptureRequest(
    this._inner, {
    required this.method,
    required this.url,
    required this.startedAt,
    required this.route,
    required this.redactSensitiveHeaders,
  });

  final HttpClientRequest _inner;
  @override
  final String method;
  final String url;
  final DateTime startedAt;
  final String? route;
  final bool redactSensitiveHeaders;

  final BytesBuilder _reqBody = BytesBuilder(copy: false);
  bool _emitted = false;

  void _take(List<int> data) {
    final max = PerfNetworkStore.instance.maxBodyBytes;
    final have = _reqBody.length;
    if (have >= max) return;
    final room = max - have;
    if (data.length <= room) {
      _reqBody.add(data);
    } else {
      _reqBody.add(data.sublist(0, room));
    }
  }

  void _emitOpenFailure(Object error) {
    if (_emitted) return;
    _emitted = true;
    final reqBytes = _reqBody.takeBytes();
    final decoded = _decodeBody(reqBytes, headers.contentType?.mimeType);
    try {
      PerfNetworkStore.instance.add(
        NetworkRequest(
          url: url,
          method: method,
          statusCode: -1,
          durationMs: DateTime.now().difference(startedAt).inMilliseconds,
          responseBytes: 0,
          startedAt: startedAt.toIso8601String(),
          route: route,
          requestHeaders: _headersMap(headers, redactSensitiveHeaders),
          requestBody: decoded.$1,
          requestBodyTruncated: decoded.$2 ||
              reqBytes.length >= PerfNetworkStore.instance.maxBodyBytes,
          requestBytes: reqBytes.length,
          error: error.toString(),
          source: 'full',
        ),
      );
    } catch (_) {}
  }

  @override
  Future<HttpClientResponse> close() async {
    try {
      final reqBytes = _reqBody.toBytes();
      final reqDecoded = _decodeBody(reqBytes, headers.contentType?.mimeType);
      final reqHeaders = _headersMap(headers, redactSensitiveHeaders);
      final response = await _inner.close();
      return _CaptureResponse(
        response,
        url: url,
        method: method,
        startedAt: startedAt,
        route: route,
        requestHeaders: reqHeaders,
        requestBody: reqDecoded.$1,
        requestBodyTruncated: reqDecoded.$2 ||
            reqBytes.length >= PerfNetworkStore.instance.maxBodyBytes,
        requestBytes: reqBytes.length,
        redactSensitiveHeaders: redactSensitiveHeaders,
        onEmitted: () => _emitted = true,
      );
    } catch (e) {
      _emitOpenFailure(e);
      rethrow;
    }
  }

  /// Prefer [close] so capture wraps the response (unlike Sleuth's `_inner.done`).
  @override
  Future<HttpClientResponse> get done => close();

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  Uri get uri => _inner.uri;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  @override
  void add(List<int> data) {
    _take(data);
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) {
    final tee = stream.map((chunk) {
      _take(chunk);
      return chunk;
    });
    return _inner.addStream(tee);
  }

  @override
  Future flush() => _inner.flush();

  @override
  void write(Object? object) {
    final s = object?.toString() ?? '';
    _take(encoding.encode(s));
    _inner.write(object);
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    write(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    _take([charCode]);
    _inner.writeCharCode(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }
}

/// Same Stream subclass trick as Sleuth: all drain/toList/forEach go through
/// [listen], so we always see the body.
class _CaptureResponse extends Stream<List<int>> implements HttpClientResponse {
  _CaptureResponse(
    this._inner, {
    required this.url,
    required this.method,
    required this.startedAt,
    required this.route,
    required this.requestHeaders,
    required this.requestBody,
    required this.requestBodyTruncated,
    required this.requestBytes,
    required this.redactSensitiveHeaders,
    required this.onEmitted,
  });

  final HttpClientResponse _inner;
  final String url;
  final String method;
  final DateTime startedAt;
  final String? route;
  final Map<String, String> requestHeaders;
  final String? requestBody;
  final bool requestBodyTruncated;
  final int requestBytes;
  final bool redactSensitiveHeaders;
  final void Function() onEmitted;

  final BytesBuilder _resBody = BytesBuilder(copy: false);

  void _emitRecord(int bytesReceived, {bool cancelled = false, String? error}) {
    onEmitted();
    final max = PerfNetworkStore.instance.maxBodyBytes;
    final captured = _resBody.takeBytes();
    final mime = headers.contentType?.mimeType;
    final decoded = _decodeBody(captured, mime);
    try {
      PerfNetworkStore.instance.add(
        NetworkRequest(
          url: url,
          method: method,
          statusCode: statusCode,
          durationMs: DateTime.now().difference(startedAt).inMilliseconds,
          responseBytes: bytesReceived,
          startedAt: startedAt.toIso8601String(),
          route: route,
          cancelled: cancelled,
          contentType: mime,
          requestHeaders: requestHeaders,
          requestBody: requestBody,
          requestBodyTruncated: requestBodyTruncated,
          requestBytes: requestBytes,
          responseHeaders: _headersMap(headers, redactSensitiveHeaders),
          responseBody: decoded.$1,
          responseBodyTruncated: decoded.$2 ||
              captured.length >= max ||
              bytesReceived > captured.length,
          error: error,
          source: 'full',
        ),
      );
    } catch (_) {}
  }

  void _takeChunk(List<int> data) {
    final max = PerfNetworkStore.instance.maxBodyBytes;
    final have = _resBody.length;
    if (have >= max) return;
    final room = max - have;
    if (data.length <= room) {
      _resBody.add(data);
    } else {
      _resBody.add(data.sublist(0, room));
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    // Sleuth pattern: proxy owns terminal handlers permanently so
    // drain()/asFuture()/onDone rebinding cannot drop the record.
    final sub = _CaptureSubscription<List<int>>._((bytes, {cancelled = false, error}) {
      _emitRecord(bytes, cancelled: cancelled, error: error);
    });
    sub._terminated.future.ignore();
    sub._userOnData = onData;
    sub._userOnError = onError;
    sub._userOnDone = onDone;

    sub._inner = _inner.listen(
      (chunk) {
        sub._bytesReceived += chunk.length;
        _takeChunk(chunk);
        sub._userOnData?.call(chunk);
      },
      onError: (Object error, [StackTrace? stackTrace]) {
        final stack = stackTrace ?? StackTrace.empty;
        sub._emitOnTerminalWithError(error, stack);
        final handler = sub._userOnError;
        if (handler != null) {
          if (handler is void Function(Object, StackTrace)) {
            handler(error, stack);
          } else {
            (handler as void Function(Object))(error);
          }
        }
      },
      onDone: () {
        sub._emitOnTerminal();
        sub._userOnDone?.call();
      },
      cancelOnError: cancelOnError,
    );

    return sub;
  }

  @override
  int get statusCode => _inner.statusCode;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  int get contentLength => _inner.contentLength;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  bool get isBroadcast => _inner.isBroadcast;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) =>
      _inner.redirect(method, url, followLoops);

  @override
  Future<Socket> detachSocket() => _inner.detachSocket();

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
}

/// Mirrors Sleuth `_MonitoringSubscription`: owns terminal signal + emit.
class _CaptureSubscription<T> implements StreamSubscription<T> {
  _CaptureSubscription._(this._emit);

  late StreamSubscription<T> _inner;
  final Completer<void> _terminated = Completer<void>();
  int _bytesReceived = 0;
  bool _terminatedFlag = false;

  final void Function(int bytesReceived, {bool cancelled, String? error}) _emit;

  void Function(T data)? _userOnData;
  Function? _userOnError;
  void Function()? _userOnDone;

  void _emitOnTerminal({bool cancelled = false, String? error}) {
    if (_terminatedFlag) return;
    _terminatedFlag = true;
    _emit(_bytesReceived, cancelled: cancelled, error: error);
    if (!_terminated.isCompleted) {
      _terminated.complete();
    }
  }

  void _emitOnTerminalWithError(Object error, StackTrace stackTrace) {
    if (_terminatedFlag) return;
    _terminatedFlag = true;
    _emit(_bytesReceived, cancelled: false, error: error.toString());
    if (!_terminated.isCompleted) {
      _terminated.completeError(error, stackTrace);
    }
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) =>
      _terminated.future.then<E>((_) => futureValue as E);

  @override
  Future<void> cancel() {
    _emitOnTerminal(cancelled: true);
    return _inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) {
    _userOnData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _userOnError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _userOnDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;
}

Map<String, String> _headersMap(HttpHeaders headers, bool redact) {
  const sensitive = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
    'x-auth-token',
  };
  final out = <String, String>{};
  headers.forEach((name, values) {
    final joined = values.join(', ');
    if (redact && sensitive.contains(name.toLowerCase())) {
      out[name] = joined.isEmpty ? '' : '***';
    } else {
      out[name] = joined;
    }
  });
  return out;
}

(String?, bool) _decodeBody(List<int> bytes, String? mimeType) {
  if (bytes.isEmpty) return (null, false);
  final mime = (mimeType ?? '').toLowerCase();
  final looksText = mime.startsWith('text/') ||
      mime.contains('json') ||
      mime.contains('xml') ||
      mime.contains('javascript') ||
      mime.contains('x-www-form-urlencoded') ||
      mime.isEmpty;
  if (!looksText) {
    return ('[binary ${bytes.length} bytes · $mime]', false);
  }
  try {
    final text = utf8.decode(bytes, allowMalformed: true);
    final bad = '\uFFFD'.allMatches(text).length;
    if (bad > text.length * 0.1 && text.length > 32) {
      return ('[binary ${bytes.length} bytes]', false);
    }
    return (text, false);
  } catch (_) {
    return ('[binary ${bytes.length} bytes]', false);
  }
}
