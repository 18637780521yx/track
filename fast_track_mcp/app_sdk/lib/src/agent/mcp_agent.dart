import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_skill/flutter_skill.dart';
import 'package:get/get.dart';

import '../bridge/bridge_server.dart';
import '../detect/anr_watchdog.dart';
import '../detect/crash_handler.dart';
import '../detect/jank_monitor.dart';
import '../detect/memory_monitor.dart';
import '../gesture/manual_gesture_recorder.dart';
import '../leak/getx_leak_hook.dart' as getx_hook;
import '../leak/leak_online.dart';
import '../leak/transition_leak_tracker.dart';
import '../leak/transition_ledger.dart';
import '../lifecycle/app_lifecycle_tracker.dart';
import '../network/network_capture.dart';
import 'fast_track_bridge.dart';

/// Entry point for embedding Fast Track MCP into a Flutter app.
///
/// Crash / ANR / jank / RSS 由本 SDK 检测并 [FastTracker.track]；
/// Bridge 仅服务 MCP 自动化（开/停/记步 → 埋点，无本地报告）。
class FastTrackMcp {
  static FastTrackMcpBridgeServer? _bridge;
  static bool _initialized = false;
  static Future<void>? _startFuture;

  static FastTrackMcpBridgeServer? get bridge => _bridge;

  static int? get boundPort =>
      _bridge?.isRunning == true ? _bridge!.boundPort : null;

  static Future<void>? get ready => _startFuture;

  /// Release 下启转场观察者 / 手势（仍不启 Bridge）。由宿主在 init 后置 true。
  static bool releaseUiHooks = false;

  static List<NavigatorObserver> get navigatorObservers =>
      getx_hook.perfNavigatorObservers(
        enabled: !kReleaseMode || LeakOnline.instance.active || releaseUiHooks,
      );

  static List<GetPage<dynamic>> instrumentGetPages(
    List<GetPage<dynamic>> pages,
  ) =>
      getx_hook.instrumentGetPages(pages);

  /// 请在 [FastTrackMcpCrashHandler.run] 内先 [FastTracker.init]，再调本方法。
  static Future<void> ensureInitialized({
    String host = '127.0.0.1',
    int port = 19288,
    int waitStableMs = 500,
    bool enableFlutterSkill = true,
    // Initial opt-in for Debug/Profile only. Release never installs a proxy.
    bool enableHttpCapture = false,
    bool leakTrackEnabled = true,
    int transitionSettleMs = 1500,
    int leakConfirmRounds = 2,
    double leakRssRetainMb = 5,
    bool alertOnWeakRef = true,
    bool requireMultiRound = true,
    bool alertOnRssRetain = true,
    bool leakVmDeepProbe = false,
    bool enableAnrWatchdog = true,
    Duration anrTimeout = const Duration(seconds: 5),
    bool enableJankMonitor = true,
    int? jankFpsTarget,
    bool enableMemoryMonitor = true,
    int memoryPressureBytes = 512 * 1024 * 1024,
    bool enableVmMemoryMonitoring = true,
    bool leakOnlineEnabled = false,
    double leakSampleRate = 0.0,
    void Function(Map<String, dynamic> event)? onLeakOnlineEvent,
    bool wireLeakOnlineToFastTrack = true,
  }) async {
    await FastTrackMcpCrashHandler.ensureNativeInitialized();
    if (_initialized) return;
    _initialized = true;

    final leakHandler = onLeakOnlineEvent ??
        (wireLeakOnlineToFastTrack
            ? FastTrackMcpBridge.forwardLeakOnlineEvent
            : null);

    LeakOnline.instance.configure(
      enabled: leakOnlineEnabled,
      sampleRate: leakSampleRate,
      onEvent: leakHandler,
    );

    if (enableAnrWatchdog) {
      unawaited(FastTrackMcpAnrWatchdog.start(timeout: anrTimeout));
    }
    if (enableJankMonitor) {
      FastTrackMcpJankMonitor.start(fpsTarget: jankFpsTarget);
    }
    if (enableMemoryMonitor) {
      FastTrackMcpMemoryMonitor.start(
        pressureBytes: memoryPressureBytes,
        enableVmMonitoring: enableVmMemoryMonitoring,
      );
    }

    TransitionLeakTracker.instance.configure(
      enabled: leakTrackEnabled,
      settleMs: transitionSettleMs,
      leakConfirmRounds: leakConfirmRounds,
      rssRetainMb: leakRssRetainMb,
      alertOnWeakRef: alertOnWeakRef,
      requireMultiRound: requireMultiRound,
      alertOnRssRetain: alertOnRssRetain,
      leakVmDeepProbe: leakVmDeepProbe,
    );
    TransitionLedger.instance.settleMs = transitionSettleMs;

    // Opt-in capture is restricted to Debug/Profile, including direct installs.
    if (enableHttpCapture && !kReleaseMode) {
      FastTrackMcpNetwork.install(captureBodyOnFailureOnly: false);
    }

    // Background queue flushing is required in release as well.
    AppLifecycleTracker.instance.ensureStarted();
    if (kReleaseMode) {
      if (LeakOnline.instance.active) {
        debugPrint(
          '[FastTrackMcp] release online lite active '
          '(sampleRate=$leakSampleRate)',
        );
      } else {
        debugPrint('[FastTrackMcp] release: monitors on, bridge idle');
      }
      return;
    }

    // 生命周期优先于 flutter_skill，避免 skill 初始化失败时冷启动永远不埋点。
    AppLifecycleTracker.instance.ensureStarted();
    // 静默手势 → ui_tap / ui_scroll 埋点（无录制条 / 无本地报告）
    ManualGestureRecorder.instance.ensureStarted();

    if (enableFlutterSkill) {
      try {
        FastTrackMcpCrashHandler.preserveFlutterErrorHandler(
          () => FlutterSkillBinding.ensureInitialized(),
        );
      } catch (e, st) {
        debugPrint('[FastTrackMcp] flutter_skill init failed: $e\n$st');
      }
    }

    _bridge = FastTrackMcpBridgeServer(
      host: host,
      port: port,
      waitStableMs: waitStableMs,
    );
    _startFuture = _startBridgeDeferred();
  }

  static void installHttpCapture({
    int maxBodyBytes = PerfNetworkStore.defaultMaxBodyBytes,
    bool redactSensitiveHeaders = true,
    List<String>? allowedHosts,
    bool httpsOnly = false,
    bool allowHttpLoopback = true,
    List<String>? excludeUrlSubstrings,
    bool captureBodyOnFailureOnly = false,
    bool allowInRelease = false,
  }) {
    if (kReleaseMode) return;
    FastTrackMcpNetwork.install(
      maxBodyBytes: maxBodyBytes,
      redactSensitiveHeaders: redactSensitiveHeaders,
      allowedHosts: allowedHosts,
      httpsOnly: httpsOnly,
      allowHttpLoopback: allowHttpLoopback,
      excludeUrlSubstrings: excludeUrlSubstrings,
      captureBodyOnFailureOnly: captureBodyOnFailureOnly,
      allowInRelease: allowInRelease,
    );
  }

  static void installHttpCaptureDeferred({
    int maxBodyBytes = PerfNetworkStore.defaultMaxBodyBytes,
    bool redactSensitiveHeaders = true,
    List<String>? allowedHosts,
    bool httpsOnly = false,
    bool allowHttpLoopback = true,
    List<String>? excludeUrlSubstrings,
    bool captureBodyOnFailureOnly = false,
    bool allowInRelease = false,
  }) {
    if (kReleaseMode) return;
    FastTrackMcpNetwork.installDeferred(
      maxBodyBytes: maxBodyBytes,
      redactSensitiveHeaders: redactSensitiveHeaders,
      allowedHosts: allowedHosts,
      httpsOnly: httpsOnly,
      allowHttpLoopback: allowHttpLoopback,
      excludeUrlSubstrings: excludeUrlSubstrings,
      captureBodyOnFailureOnly: captureBodyOnFailureOnly,
      allowInRelease: allowInRelease,
    );
  }

  static Future<void> _startBridgeDeferred() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final bridge = _bridge;
    if (bridge == null) return;
    try {
      await bridge.start();
      AppLifecycleTracker.instance.noteColdStart(
        route: FastTrackMcpNetwork.currentRoute(),
      );
      debugPrint(
        '[FastTrackMcp] bridge ready at http://${bridge.host}:${bridge.boundPort}',
      );
    } catch (e, st) {
      debugPrint('[FastTrackMcp] bridge start failed: $e\n$st');
    }
  }

  /// Test / hot-restart helper.
  @visibleForTesting
  static void debugReset() {
    _initialized = false;
    _startFuture = null;
    _bridge = null;
  }
}
