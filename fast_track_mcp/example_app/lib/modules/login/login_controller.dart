import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/auth_service.dart';
import '../../demo_api.dart';

class LoginController extends GetxController {
  final emailController = TextEditingController(text: 'test@test.com');
  final passwordController = TextEditingController();

  final error = RxnString();
  final loading = false.obs;

  @override
  void onClose() {
    emailController.dispose();
    passwordController.dispose();
    super.onClose();
  }

  Future<void> login() async {
    if (passwordController.text.isEmpty) {
      error.value = '请输入密码';
      return;
    }
    error.value = null;
    loading.value = true;
    try {
      final email = emailController.text.trim();
      final res = await DemoApi.instance.login(
        email: email,
        password: passwordController.text,
      );
      if (res['ok'] != true) {
        error.value = res['msg']?.toString() ?? '登录失败';
        loading.value = false;
        return;
      }
      Get.find<AuthService>().applyLogin(
        email: res['user']?.toString() ?? email,
        displayName: res['displayName']?.toString() ?? email,
        avatarUrl: res['avatarUrl']?.toString(),
      );
      await Get.offAllNamed(AppRoutes.home);
    } catch (e) {
      error.value = '登录请求失败: $e';
      loading.value = false;
    }
  }
}
