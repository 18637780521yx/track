import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MainController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late final TabController tabController;

  @override
  void onInit() {
    super.onInit();
    tabController = TabController(length: 3, vsync: this);
  }

  void goHomeTab() => tabController.animateTo(0);

  void goDiscoverTab() => tabController.animateTo(1);

  void goMineTab() => tabController.animateTo(2);

  @override
  void onClose() {
    tabController.dispose();
    super.onClose();
  }
}
