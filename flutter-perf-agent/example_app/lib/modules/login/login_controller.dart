import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:sleuth/sleuth.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/auth_service.dart';
import '../../demo_api.dart';

class LoginController extends GetxController {
  final emailController = TextEditingController(text: 'test@test.com');
  final passwordController = TextEditingController();

  final error = RxnString();
  final loading = false.obs;

  @override
  void onReady() {
    super.onReady();
    // TTI: first interactive frame on the login landing route.
    if (!kReleaseMode) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        Sleuth.markInteractive();
      });
    }
  }

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
