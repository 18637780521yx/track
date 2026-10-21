import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:get/get.dart';

import '../home/home_controller.dart';
import '../profile/profile_controller.dart';
import 'main_controller.dart';

class MainBinding extends Bindings {
  @override
  void dependencies() {
    // Tab shell controllers outlive `/home#*` logical switches — do not
    // WeakRef-track them (avoids false transition_memory_leak on tab change).
    PerfDi.lazyPut(MainController.new, trackLeak: false);
    PerfDi.lazyPut(HomeController.new, trackLeak: false);
    PerfDi.lazyPut(ProfileController.new, trackLeak: false);
  }
}
