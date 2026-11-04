import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:get/get.dart';

import 'profile_controller.dart';

class ProfileBinding extends Bindings {
  @override
  void dependencies() {
    // FastTrackMcpDi + instrumentGetPages 路由 scope → 自动 track @ /profile。
    // 每次 push 新建；pop 后仍被 [ProfilePushController.demoRetain] 握住。
    FastTrackMcpDi.lazyPut(ProfilePushController.new, fenix: true);
  }
}
