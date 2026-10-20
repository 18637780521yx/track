import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_skill/flutter_skill.dart';
import 'package:get/get.dart';

import 'bridge_server.dart';
import 'getx_leak_hook.dart' as getx_hook;
import 'manual_gesture_recorder.dart';
import 'network_capture.dart';
import 'session_journal.dart';
import 'transition_leak_tracker.dart';
import 'transition_ledger.dart';

/// Entry point for embedding Flutter-Perf-Agent into a Flutter app.
class PerfAgent {
  static PerfBridgeServer? _bridge;
  static bool _initialized = false;
  static Future<void>? _startFuture;

  static PerfBridgeServer? get bridge => _bridge;

  /// Actual bound port after bridge start (may differ from [port] on fallback).
  static int? get boundPort =>
      _bridge?.isRunning == true ? _bridge!.boundPort : null;

  /// Completes when the deferred bridge bind finishes (success or failure).
  static Future<void>? get ready => _startFuture;

  /// [TransitionObserver] for [GetMaterialApp.navigatorObservers] /
  /// [MaterialApp.navigatorObservers]. Empty in release.
  static List<NavigatorObserver> get navigatorObservers =>
      getx_hook.perfNavigatorObservers(enabled: !kReleaseMode);

  /// Prepend [PerfLeakMiddleware] so Bindings run under a route scope for
  /// [PerfDi]. Recurses into nested [GetPage.children].
  static List<GetPage<dynamic>> instrumentGetPages(
    List<GetPage<dynamic>> pages,
  ) =>
      getx_hook.instrumentGetPages(pages);

  /// Initialize flutter-skill + local perf HTTP bridge + unified journal.
  ///
  /// Call once before [runApp]. Wrap the app with `Sleuth.track(child: ...)`
  /// yourself. Prefer `enableNetworkMonitoring: false` so PerfAgent owns
  /// [HttpOverrides] for full header/body capture — then call
  /// [installHttpCaptureDeferred] after `Sleuth.track`.
  ///
  /// Wrap root with [PerfRecordingBanner] (or use [builder]) so manual sessions
  /// can be stopped from the in-app banner.
  static Future<void> ensureInitialized({
    String host = '127.0.0.1',
    int port = 19288,
    int waitStableMs = 500,
    bool enableFlutterSkill = true,
    bool enableManualRecording = true,
    bool autoSessionOnManual = true,
    String reportsDir = 'reports',
    /// PRD `leakTrackEnabled` — WeakRef transition leak probes.
    bool leakTrackEnabled = true,
    /// PRD `transitionSettleMs` — wait after pop before WeakRef check.
    int transitionSettleMs = 1500,
    /// PRD `leakConfirmRounds` — consecutive pops for stair/hold confirm.
    int leakConfirmRounds = 2,
    /// RSS retain (MB) auxiliary alert threshold.
    double leakRssRetainMb = 5,
    /// Bind Sleuth heap_growing / stream_resource_growth to transition windows.
    bool sleuthBindEnabled = true,
  }) async {
    if (_initialized) return;
    _initialized = true;

    if (kReleaseMode) {
      debugPrint('[PerfAgent] skipped in release mode');
      return;
    }

    SessionJournal.instance.manualRecording = enableManualRecording;
    SessionJournal.instance.autoSessionOnManual = autoSessionOnManual;
    SessionJournal.instance.reportsDir = reportsDir;

    TransitionLeakTracker.instance.configure(
      enabled: leakTrackEnabled,
      settleMs: transitionSettleMs,
      leakConfirmRounds: leakConfirmRounds,
      rssRetainMb: leakRssRetainMb,
      sleuthBindEnabled: sleuthBindEnabled,
    );
    TransitionLedger.instance.settleMs = transitionSettleMs;

    if (enableFlutterSkill) {
      FlutterSkillBinding.ensureInitialized();
    }

    if (enableManualRecording) {
      ManualGestureRecorder.instance.ensureStarted();
    }

    _bridge = PerfBridgeServer(
      host: host,
      port: port,
      waitStableMs: waitStableMs,
    );

    _startFuture = _startBridgeDeferred();
  }

  /// Full HTTP capture (URL / headers / body) into [PerfNetworkStore].
  ///
  /// [allowedHosts]: business API hosts (`host` or `host:port`). Empty = all.
  /// [httpsOnly]: only HTTPS; loopback HTTP allowed when [allowHttpLoopback].
  static void installHttpCapture({
    int maxBodyBytes = PerfNetworkStore.defaultMaxBodyBytes,
    bool redactSensitiveHeaders = true,
    List<String>? allowedHosts,
    bool httpsOnly = false,
    bool allowHttpLoopback = true,
    List<String>? excludeUrlSubstrings,
  }) {
    PerfNetworkCapture.install(
      maxBodyBytes: maxBodyBytes,
      redactSensitiveHeaders: redactSensitiveHeaders,
      allowedHosts: allowedHosts,
      httpsOnly: httpsOnly,
      allowHttpLoopback: allowHttpLoopback,
      excludeUrlSubstrings: excludeUrlSubstrings,
    );
  }

  /// Install now + delayed retries after `Sleuth.track`.
  static void installHttpCaptureDeferred({
    int maxBodyBytes = PerfNetworkStore.defaultMaxBodyBytes,
    bool redactSensitiveHeaders = true,
    List<String>? allowedHosts,
    bool httpsOnly = false,
    bool allowHttpLoopback = true,
    List<String>? excludeUrlSubstrings,
  }) {
    PerfNetworkCapture.installDeferred(
      maxBodyBytes: maxBodyBytes,
      redactSensitiveHeaders: redactSensitiveHeaders,
      allowedHosts: allowedHosts,
      httpsOnly: httpsOnly,
      allowHttpLoopback: allowHttpLoopback,
      excludeUrlSubstrings: excludeUrlSubstrings,
    );
  }

  static Future<void> _startBridgeDeferred() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final bridge = _bridge;
    if (bridge == null) return;
    try {
      await bridge.start();
      debugPrint(
        '[PerfAgent] bridge ready at http://${bridge.host}:${bridge.boundPort}',
      );
    } catch (e, st) {
      debugPrint('[PerfAgent] bridge start failed: $e\n$st');
    }
  }

  static Future<void> shutdown() async {
    await _bridge?.stop();
    _bridge = null;
    _initialized = false;
    _startFuture = null;
  }
}
