import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'login_controller.dart';

class LoginPage extends GetView<LoginController> {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Perf Agent Demo',
                  key: const Key('brand_title'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  '登录 → AppBar Tabs（首页 / 发现 / 我的）',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Semantics(
                  label: '账号输入框',
                  textField: true,
                  child: TextField(
                    key: const Key('email_field'),
                    controller: controller.emailController,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  label: '密码输入框',
                  textField: true,
                  child: TextField(
                    key: const Key('password_field'),
                    controller: controller.passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Obx(() {
                  final err = controller.error.value;
                  if (err == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(err, style: const TextStyle(color: Colors.red)),
                  );
                }),
                const SizedBox(height: 20),
                Obx(
                  () => Semantics(
                    label: '登录按钮',
                    button: true,
                    child: FilledButton(
                      key: const Key('login_button'),
                      onPressed:
                          controller.loading.value ? null : controller.login,
                      child: Text(
                        controller.loading.value ? '登录中…' : '登录',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
