import 'package:get/get.dart';

import 'profile_controller.dart';

class ProfileBinding extends Bindings {
  @override
  void dependencies() {
    // 每次 push 新建，pop 后仍被 [ProfilePushController.demoRetain] 握住。
    Get.lazyPut(ProfilePushController.new, fenix: true);
  }
}
