import 'package:flutter_skill/flutter_skill.dart';
import 'package:flutter/foundation.dart'; // For kDebugMode
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:get/get.dart';
import 'package:sleuth/sleuth.dart';

import 'app/routes/app_pages.dart';
import 'app/routes/app_routes.dart';
import 'app/services/auth_service.dart';
import 'demo_api.dart';
import 'modules/main/main_controller.dart';
import 'sleuth_demos/custom_detectors/01_simple_structural_detector.dart';
import 'sleuth_demos/custom_detectors/02_runtime_callback_detector.dart';
import 'sleuth_demos/custom_detectors/03_hybrid_vm_structural_detector.dart';

Future<void> main() async {
  // Capture TTFF from Dart entry → first frame (before runApp).
  Sleuth.init();

  // Release online lite accept: flutter run --release --dart-define=LEAK_ONLINE=true
  // (sampleRate 1 + print events; do not ship with this define on by default.)
  const leakOnline = bool.fromEnvironment('LEAK_ONLINE');

  if (!kReleaseMode || leakOnline) {
    await PerfAgent.ensureInitialized(
      host: '127.0.0.1',
      port: 19288,
      waitStableMs: 500,
      enableManualRecording: true,
      autoSessionOnManual: true,
      // Shared with mcp_server/perf_agent_config.json reportsDir when cwd is repo.
      reportsDir: 'reports',
      leakTrackEnabled: true,
      transitionSettleMs: 1500,
      leakConfirmRounds: 2,
      // Online sampling (0.8.7): release lite path when LEAK_ONLINE=true.
      leakOnlineEnabled: leakOnline,
      leakSampleRate: leakOnline ? 1.0 : 0.0,
      onLeakOnlineEvent: leakOnline
          ? (e) => debugPrint('[LeakOnlineEvent] $e')
          : null,
    );
  }

  await DemoApi.ensureReady();
  Get.put(AuthService(), permanent: true);

  // Logical page for HTTP stamp + MCP route-steps: GetX route + main tab.
  if (!kReleaseMode) {
    PerfNetworkCapture.routeProvider = _logicalRoute;
  }

  // Capture helpers need SLEUTH_CAPTURE_MODE; deep rebuild instrumentation
  // is off in that mode (matches Sleuth official example).
  // Network: PerfAgent full capture (headers+body). Sleuth network OFF so
  // we alone own HttpOverrides (see SleuthConfig.enableNetworkMonitoring).
  const captureMode = bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  runApp(
    Sleuth.track(
      child: const PerfDemoApp(),
      // Full detector set. GC / heap / shader: flutter run --profile --no-dds
      config: SleuthConfig(
        captureMode: captureMode,
        fpsTarget: 60,
        enableNetworkMonitoring: false,
        showOverlay: true,
        autoFrameBudget: true,
        // Rebuild Hotspot + rebuild_activity need these (Sleuth example).
        enableDebugCallbacks: !captureMode && !kReleaseMode,
        enableDeepDebugInstrumentation: !captureMode && !kReleaseMode,
        customDetectors: [
          TooltipUsageDetector(),
          SlowFrameDetector(),
          RasterHotSpotDetector(),
        ],
        thresholds: const DetectorThresholds(
          memoryBudgetBytes: 512 * 1024 * 1024,
        ),
      ),
    ),
  );

  if (!kReleaseMode) {
    // Only Demo API host; httpsOnly + loopback http for local python server.
    PerfAgent.installHttpCaptureDeferred(
      allowedHosts: PerfNetworkCapture.hostsFromBaseUrls([
        DemoApi.defaultBaseUrl,
      ]),
      httpsOnly: true,
      allowHttpLoopback: true,
    );
  }
}

class PerfDemoApp extends StatelessWidget {
  const PerfDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Flutter Perf Agent Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E4F)),
        useMaterial3: true,
      ),
      initialRoute: AppPages.initial,
      getPages: AppPages.routes,
      defaultTransition: Transition.cupertino,
      // push/pop → TransitionLedger（转场 kind + 泄漏探针）
      navigatorObservers: PerfAgent.navigatorObservers,
      // Manual + MCP unified journal: banner to stop & write SDK report.
      builder: (context, child) => PerfRecordingBanner(child: child),
    );
  }
}

/// `/login`, `/home#home|discover|mine`, or `/demo/<slug>`.
String _logicalRoute() {
  var r = Get.currentRoute;
  if (r.isEmpty) r = '/';
  if (r.startsWith('/demo/')) return r;
  if (r == AppRoutes.home && Get.isRegistered<MainController>()) {
    try {
      final i = Get.find<MainController>().tabController.index;
      const names = ['home', 'discover', 'mine'];
      if (i >= 0 && i < names.length) return '$r#${names[i]}';
    } catch (_) {}
  }
  return r;
}
