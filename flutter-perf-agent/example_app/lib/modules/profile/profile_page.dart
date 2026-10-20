import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/auth_service.dart';
import 'profile_controller.dart';

class ProfilePage extends GetView<ProfileController> {
  const ProfilePage({super.key, this.embedded = false});

  /// When true, used as a Tab body (no nested Scaffold / AppBar).
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    if (!embedded) {
      return const _ProfilePushPage();
    }
    return _buildBody(context, controller);
  }

  Widget _buildBody(BuildContext context, ProfileController controller) {
    final auth = controller.auth;
    return Obx(() {
      final uploading = controller.busy.value;
      return Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (embedded)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      '个人中心',
                      key: Key('profile_title'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Center(
                  child: Semantics(
                    label: '上传头像',
                    button: true,
                    child: InkWell(
                      key: const Key('avatar_button'),
                      onTap: uploading ? null : controller.pickAndUploadAvatar,
                      customBorder: const CircleBorder(),
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          Obx(() {
                            final url = auth.avatarUrl.value;
                            final name = auth.greetingName;
                            final letter = name.isNotEmpty
                                ? String.fromCharCode(name.runes.first)
                                : '?';
                            return CircleAvatar(
                              key: const Key('profile_avatar'),
                              radius: 48,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                              backgroundImage: url == null
                                  ? null
                                  : NetworkImage(
                                      '$url?t=${DateTime.now().millisecondsSinceEpoch}',
                                    ),
                              child: url == null
                                  ? Text(
                                      letter,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium,
                                    )
                                  : null,
                            );
                          }),
                          CircleAvatar(
                            radius: 14,
                            backgroundColor:
                                Theme.of(context).colorScheme.primary,
                            child: const Icon(
                              Icons.camera_alt,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '点击头像上传',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 20),
                Obx(
                  () => Text(
                    auth.displayName.value.isNotEmpty
                        ? auth.displayName.value
                        : '未命名用户',
                    key: const Key('profile_name'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 8),
                Obx(
                  () => Text(
                    auth.email.value,
                    key: const Key('profile_email'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                const SizedBox(height: 20),
                Semantics(
                  label: '修改昵称按钮',
                  button: true,
                  child: OutlinedButton.icon(
                    key: const Key('edit_nickname_button'),
                    onPressed: uploading
                        ? null
                        : () => controller.editNickname(context),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('修改昵称'),
                  ),
                ),
                if (embedded) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    label: '打开独立个人页',
                    button: true,
                    child: FilledButton.tonalIcon(
                      key: const Key('open_profile_push_button'),
                      onPressed: () => Get.toNamed(AppRoutes.profile),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('打开独立个人页（泄漏多轮演示）'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    label: '打开泄漏Dialog',
                    button: true,
                    child: OutlinedButton.icon(
                      key: const Key('open_leak_dialog_button'),
                      onPressed: uploading
                          ? null
                          : () => controller.openLeakDialog(context),
                      icon: const Icon(Icons.warning_amber_outlined),
                      label: const Text('打开泄漏 Dialog（modal 演示）'),
                    ),
                  ),
                ],
                const Spacer(),
                Semantics(
                  label: '退出登录按钮',
                  button: true,
                  child: OutlinedButton.icon(
                    key: const Key('logout_button'),
                    onPressed: uploading ? null : controller.logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('退出登录'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
          if (uploading)
            const ColoredBox(
              color: Color(0x33000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      );
    });
  }
}

/// Full-screen `/profile` push：每次进出登记一次，配合 demoRetain 出多轮泄漏。
class _ProfilePushPage extends GetView<ProfilePushController> {
  const _ProfilePushPage();

  @override
  Widget build(BuildContext context) {
    // 必须触达 controller，PerfDi.lazyPut 才会创建 → 自动 track + demoRetain。
    final _ = controller;
    final auth = Get.find<AuthService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('个人中心', key: Key('profile_title')),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Obx(
              () => Text(
                auth.displayName.value.isNotEmpty
                    ? auth.displayName.value
                    : '未命名用户',
                key: const Key('profile_name'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '泄漏多轮演示页：返回后再进一次，报告应出现 weak_ref_multi',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const Spacer(),
            Text(
              '已保留实例数：${ProfilePushController.demoRetain.length}',
              key: const Key('profile_leak_retain_count'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
