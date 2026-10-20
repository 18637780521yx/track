import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:get/get.dart';

import 'home_controller.dart';

class HomeBinding extends Bindings {
  @override
  void dependencies() {
    PerfDi.lazyPut(HomeController.new);
  }
}
