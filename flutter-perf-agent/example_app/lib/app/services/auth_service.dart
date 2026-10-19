import 'package:get/get.dart';

import '../../demo_api.dart';
import '../routes/app_routes.dart';

/// Session user after login (display name / avatar for 个人中心).
class AuthService extends GetxService {
  final email = ''.obs;
  final displayName = ''.obs;
  final avatarUrl = RxnString();
  final loggedIn = false.obs;

  String get greetingName =>
      displayName.value.trim().isNotEmpty ? displayName.value : email.value;

  void applyLogin({
    required String email,
    required String displayName,
    String? avatarUrl,
  }) {
    this.email.value = email;
    this.displayName.value = displayName;
    this.avatarUrl.value = avatarUrl;
    loggedIn.value = true;
  }

  void applyUser(Map<String, dynamic> user) {
    email.value = user['email']?.toString() ?? email.value;
    displayName.value = user['displayName']?.toString() ?? displayName.value;
    final a = user['avatarUrl']?.toString();
    avatarUrl.value = (a == null || a.isEmpty) ? null : a;
    loggedIn.value = true;
  }

  Future<void> refreshProfile() async {
    final me = await DemoApi.instance.fetchMe();
    if (me != null) applyUser(me);
  }

  Future<void> logout() async {
    await DemoApi.instance.logout();
    email.value = '';
    displayName.value = '';
    avatarUrl.value = null;
    loggedIn.value = false;
    await Get.offAllNamed(AppRoutes.login);
  }
}
