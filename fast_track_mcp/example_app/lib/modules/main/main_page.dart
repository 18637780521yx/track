import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../home/home_page.dart';
import '../profile/profile_page.dart';
import 'discover_tab.dart';
import 'main_controller.dart';

class MainPage extends GetView<MainController> {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        key: const Key('main_app_bar'),
        title: const Text('Perf Demo', key: Key('home_title')),
        bottom: TabBar(
          key: const Key('main_tab_bar'),
          controller: controller.tabController,
          tabs: const [
            Tab(key: Key('tab_home'), text: '首页'),
            Tab(key: Key('tab_discover'), text: '场景'),
            Tab(key: Key('tab_mine'), text: '我的'),
          ],
        ),
        actions: [
          Semantics(
            label: '个人中心按钮',
            button: true,
            child: IconButton(
              key: const Key('profile_button'),
              tooltip: '我的',
              icon: const Icon(Icons.person_outline),
              onPressed: controller.goMineTab,
            ),
          ),
        ],
      ),
      body: TabBarView(
        key: const Key('main_tab_view'),
        controller: controller.tabController,
        children: const [
          HomePage(),
          DiscoverTab(),
          ProfilePage(embedded: true),
        ],
      ),
    );
  }
}
