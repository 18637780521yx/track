import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';
import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:get/get.dart';

import 'app/routes/app_pages.dart';
import 'app/routes/app_routes.dart';
import 'app/services/auth_service.dart';
import 'demo_api.dart';
import 'modules/main/main_controller.dart';

Future<void> main() async {
  await FastTrackMcpCrashHandler.run(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await FastTracker.init(
      url: 'https://track.example.local/v1/events',
      config: const TrackerConfig(dryRun: true, enableDebugLog: true),
    );

    const leakOnline = bool.fromEnvironment('LEAK_ONLINE');

    if (!kReleaseMode || leakOnline) {
      await FastTrackMcp.ensureInitialized(
        host: '127.0.0.1',
        port: 19288,
        waitStableMs: 500,
        leakTrackEnabled: true,
        leakOnlineEnabled: leakOnline,
        leakSampleRate: leakOnline ? 1.0 : 0.0,
        wireLeakOnlineToFastTrack: true,
      );
    }

    try {
      await DemoApi.ensureReady();
    } catch (e) {
      debugPrint('[boot] DemoApi not ready: $e');
    }
    Get.put(AuthService(), permanent: true);

    if (!kReleaseMode) {
      FastTrackMcpNetwork.routeProvider = _logicalRoute;
    }

    runApp(const FastTrackMcpDemoApp());
  });
}

class FastTrackMcpDemoApp extends StatelessWidget {
  const FastTrackMcpDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Fast Track MCP Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E4F)),
        useMaterial3: true,
      ),
      initialRoute: AppPages.initial,
      getPages: AppPages.routes,
      defaultTransition: Transition.cupertino,
      navigatorObservers: FastTrackMcp.navigatorObservers,
    );
  }
}

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
