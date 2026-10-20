import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:get/get.dart';

import '../home/home_controller.dart';
import '../profile/profile_controller.dart';
import 'main_controller.dart';

class MainBinding extends Bindings {
  @override
  void dependencies() {
    PerfDi.lazyPut(MainController.new);
    PerfDi.lazyPut(HomeController.new);
    PerfDi.lazyPut(ProfileController.new);
  }
}
