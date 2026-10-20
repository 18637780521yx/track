import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:get/get.dart';

import 'login_controller.dart';

class LoginBinding extends Bindings {
  @override
  void dependencies() {
    PerfDi.lazyPut(LoginController.new);
  }
}
