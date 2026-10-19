import 'package:get/get.dart';

import '../home/home_controller.dart';
import '../profile/profile_controller.dart';
import 'main_controller.dart';

class MainBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(MainController.new);
    Get.lazyPut(HomeController.new);
    Get.lazyPut(ProfileController.new);
  }
}
