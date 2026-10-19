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

  if (!kReleaseMode) {
    await PerfAgent.ensureInitialized(
      host: '127.0.0.1',
      port: 19288,
      waitStableMs: 500,
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
  const captureMode = bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  runApp(
    Sleuth.track(
      child: const PerfDemoApp(),
      // Full detector set. GC / heap / shader: flutter run --profile --no-dds
      config: SleuthConfig(
        captureMode: captureMode,
        fpsTarget: 60,
        enableNetworkMonitoring: true,
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

  // After Sleuth.track so we can wrap its HttpOverrides and capture
  // request/response headers + bodies into perf reports.
  if (!kReleaseMode) {
    PerfAgent.installHttpCaptureDeferred();
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
