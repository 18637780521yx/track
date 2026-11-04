import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:get/get.dart';

import 'login_controller.dart';

class LoginBinding extends Bindings {
  @override
  void dependencies() {
    FastTrackMcpDi.lazyPut(LoginController.new);
  }
}
