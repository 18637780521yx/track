import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:get/get.dart';

import '../home/home_controller.dart';
import '../profile/profile_controller.dart';
import 'main_controller.dart';

class MainBinding extends Bindings {
  @override
  void dependencies() {
    // Tab shell controllers outlive `/home#*` logical switches — do not
    // WeakRef-track them (avoids false memory_leak on tab change).
    FastTrackMcpDi.lazyPut(MainController.new, trackLeak: false);
    FastTrackMcpDi.lazyPut(HomeController.new, trackLeak: false);
    FastTrackMcpDi.lazyPut(ProfileController.new, trackLeak: false);
  }
}
