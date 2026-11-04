import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fast_track_mcp_protocol/fast_track_mcp_protocol.dart';

import '../network/network_capture.dart';
import '../session/session_journal.dart';

/// D1: Flutter / uncaught errors → session timeline `alertType=crash`.
///
/// Hooks [FlutterError.onError] and [PlatformDispatcher.onError], chaining
/// any previous handlers. For Zone errors, call [report] from
/// [runZonedGuarded] (see example_app `main`).
///
/// Only writes while [SessionJournal.isActive]. Live report is refreshed
/// (best-effort) so a subsequent fatal exit still leaves a trail.
class CrashCapture {
  CrashCapture._();
  static final CrashCapture instance = CrashCapture._();

  bool _started = false;
  FlutterExceptionHandler? _prevFlutter;
  bool Function(Object error, StackTrace stack)? _prevPlatform;

  /// Max stack characters kept in the alert value.
  static const int maxStackChars = 4000;

  /// Dedup identical errors within this window (framework may re-report).
  static const Duration dedupeWindow = Duration(seconds: 2);
  String? _lastFp;
  DateTime? _lastAt;

  void ensureStarted() {
    if (kReleaseMode || _started) return;
    _started = true;

    _prevFlutter = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      report(
        details.exceptionAsString(),
        details.stack,
        kind: 'flutter_error',
        library: details.library,
        context: details.context?.toDescription(),
        silent: details.silent,
      );
      _prevFlutter?.call(details);
    };

    _prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      report(error, stack, kind: 'uncaught', fatal: true);
      return _prevPlatform?.call(error, stack) ?? false;
    };

    debugPrint('[CrashCapture] started (FlutterError + PlatformDispatcher)');
  }

  void stop() {
    if (!_started) return;
    FlutterError.onError = _prevFlutter;
    PlatformDispatcher.instance.onError = _prevPlatform;
    _prevFlutter = null;
    _prevPlatform = null;
    _started = false;
    _lastFp = null;
    _lastAt = null;
  }

  /// Public entry for [runZonedGuarded] / host pipelines.
  void report(
    Object error,
    StackTrace? stack, {
    String kind = 'zone',
    bool fatal = false,
    String? library,
    String? context,
    bool silent = false,
  }) {
    if (kReleaseMode) return;
    if (silent) return;
    if (!SessionJournal.instance.isActive) return;

    final message = _shortError(error);
    final stackStr = _clipStack(stack);
    final fp = '$kind|$message|${stackStr.hashCode}';
    final now = DateTime.now();
    final lastAt = _lastAt;
    if (_lastFp == fp &&
        lastAt != null &&
        now.difference(lastAt) < dedupeWindow) {
      return;
    }
    _lastFp = fp;
    _lastAt = now;

    final route = FastTrackMcpNetwork.currentRoute();
    final at = now.toIso8601String();
    final value = <String, dynamic>{
      'kind': kind,
      'fatal': fatal,
      'error': message,
      if (stackStr.isNotEmpty) 'stack': stackStr,
      if (library != null && library.isNotEmpty) 'library': library,
      if (context != null && context.isNotEmpty) 'context': context,
      if (route != null && route.isNotEmpty) 'route': route,
      'source': 'crash_capture',
    };

    SessionJournal.instance.appendRealtimeAlert(
      AlertItem(
        type: 'crash',
        stepId: '',
        action: 'crash:$kind',
        message: fatal ? '未捕获异常：$message' : 'FlutterError：$message',
        value: value,
        at: at,
      ),
      routeHint: route,
    );

    // Best-effort persist before a possible process death.
    unawaited(SessionJournal.instance.writeLiveReport());
    debugPrint('[CrashCapture] $kind fatal=$fatal: $message');
  }

  static String _shortError(Object error) {
    final s = error is FlutterErrorDetails
        ? error.exceptionAsString()
        : error.toString();
    final one = s.split('\n').first.trim();
    if (one.length <= 200) return one;
    return '${one.substring(0, 200)}…';
  }

  static String _clipStack(StackTrace? stack) {
    if (stack == null) return '';
    final s = stack.toString();
    if (s.length <= maxStackChars) return s;
    return '${s.substring(0, maxStackChars)}\n…(truncated)';
  }
}
