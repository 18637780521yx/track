import 'package:fast_track_mcp/fast_track_mcp.dart';
import 'package:get/get.dart';

import 'home_controller.dart';

class HomeBinding extends Bindings {
  @override
  void dependencies() {
    FastTrackMcpDi.lazyPut(HomeController.new);
  }
}
