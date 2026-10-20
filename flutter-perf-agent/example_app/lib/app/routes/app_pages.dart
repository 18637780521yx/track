import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:get/get.dart';

import '../../modules/login/login_binding.dart';
import '../../modules/login/login_page.dart';
import '../../modules/main/main_binding.dart';
import '../../modules/main/main_page.dart';
import '../../modules/profile/profile_binding.dart';
import '../../modules/profile/profile_page.dart';
import 'app_routes.dart';

class AppPages {
  static const initial = AppRoutes.login;

  static final routes = PerfAgent.instrumentGetPages(<GetPage<dynamic>>[
    GetPage(
      name: AppRoutes.login,
      page: () => const LoginPage(),
      binding: LoginBinding(),
    ),
    GetPage(
      name: AppRoutes.home,
      page: () => const MainPage(),
      binding: MainBinding(),
    ),
    GetPage(
      name: AppRoutes.profile,
      page: () => const ProfilePage(),
      binding: ProfileBinding(),
    ),
  ]);
}
