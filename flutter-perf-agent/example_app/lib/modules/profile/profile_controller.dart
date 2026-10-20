import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:get/get.dart';

import '../../app/services/auth_service.dart';
import '../../demo_api.dart';

/// Push `/profile` 专用：故意保留强引用，便于 V2 多轮 WeakRef 演示。
/// 泄漏登记由 [PerfDi.lazyPut]（ProfileBinding）自动完成，此处不手写 track。
class ProfilePushController extends GetxController {
  static final List<ProfilePushController> demoRetain = [];

  @override
  void onInit() {
    super.onInit();
    if (!kReleaseMode) {
      demoRetain.add(this);
    }
  }
}

/// V3 modal 泄漏演示：Dialog 关闭后仍被静态列表握住。
class DialogLeakDemo {
  static final List<Object> retain = [];
  static const routeName = '#modal/leak_demo';
}

class ProfileController extends GetxController {
  AuthService get auth => Get.find<AuthService>();

  final busy = false.obs;

  @override
  void onInit() {
    super.onInit();
    // 登记由 MainBinding 的 PerfDi.lazyPut 完成；多轮演示走 [ProfilePushController]。
    refreshProfile();
  }

  Future<void> refreshProfile() async {
    try {
      await auth.refreshProfile();
    } catch (_) {}
  }

  Future<void> logout() => auth.logout();

  /// Open a named dialog, track a retained holder @ [DialogLeakDemo.routeName].
  Future<void> openLeakDialog(BuildContext context) async {
    if (!kReleaseMode) {
      final holder = Object();
      DialogLeakDemo.retain.add(holder);
      TransitionLeakTracker.instance.track(
        holder,
        name: 'DialogLeakHolder',
        route: DialogLeakDemo.routeName,
      );
    }
    await showDialog<void>(
      context: context,
      routeSettings: const RouteSettings(name: DialogLeakDemo.routeName),
      builder: (ctx) {
        return AlertDialog(
          title: const Text('泄漏 Dialog 演示', key: Key('leak_dialog_title')),
          content: Text(
            '关闭后 DialogLeakHolder 仍被静态列表握住'
            '（retain=${DialogLeakDemo.retain.length}）',
          ),
          actions: [
            TextButton(
              key: const Key('leak_dialog_close'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> editNickname(BuildContext context) async {
    final input = TextEditingController(text: auth.displayName.value);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('修改昵称'),
          content: TextField(
            key: const Key('nickname_field'),
            controller: input,
            maxLength: 32,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '昵称',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('nickname_save_button'),
              onPressed: () => Navigator.of(ctx).pop(input.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    input.dispose();
    if (result == null) return;
    if (result.isEmpty) {
      Get.snackbar('提示', '昵称不能为空', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    busy.value = true;
    try {
      final res = await DemoApi.instance.updateDisplayName(result);
      if (res['ok'] == true && res['user'] is Map) {
        auth.applyUser(Map<String, dynamic>.from(res['user'] as Map));
        Get.snackbar('成功', '昵称已更新', snackPosition: SnackPosition.BOTTOM);
      } else {
        Get.snackbar(
          '失败',
          res['msg']?.toString() ?? '更新失败',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    } catch (e) {
      Get.snackbar('失败', '$e', snackPosition: SnackPosition.BOTTOM);
    } finally {
      busy.value = false;
    }
  }

  Future<void> pickAndUploadAvatar() async {
    // file_picker 11.x API（13.x 的 pickFile 在本 SDK 不可用）
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final file = result?.files.isNotEmpty == true ? result!.files.first : null;
    if (file == null) return;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      Get.snackbar('失败', '无法读取图片', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    if (bytes.length > 2 * 1024 * 1024) {
      Get.snackbar('失败', '图片不能超过 2MB', snackPosition: SnackPosition.BOTTOM);
      return;
    }
    final ext = (file.extension ?? '').toLowerCase();
    var contentType = 'image/jpeg';
    if (ext == 'png') {
      contentType = 'image/png';
    } else if (ext == 'webp') {
      contentType = 'image/webp';
    } else if (ext == 'gif') {
      contentType = 'image/gif';
    }
    busy.value = true;
    try {
      final res = await DemoApi.instance.uploadAvatar(
        bytes: bytes,
        contentType: contentType,
      );
      if (res['ok'] == true && res['user'] is Map) {
        auth.applyUser(Map<String, dynamic>.from(res['user'] as Map));
        Get.snackbar('成功', '头像已更新', snackPosition: SnackPosition.BOTTOM);
      } else {
        Get.snackbar(
          '失败',
          res['msg']?.toString() ?? '上传失败',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    } catch (e) {
      Get.snackbar('失败', '$e', snackPosition: SnackPosition.BOTTOM);
    } finally {
      busy.value = false;
    }
  }
}
