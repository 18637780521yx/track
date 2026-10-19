import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'home_controller.dart';

/// Home feed tab body (AppBar lives on [MainPage]).
class HomePage extends GetView<HomeController> {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (controller.loading.value) {
        return const Center(child: CircularProgressIndicator());
      }
      final list = controller.items;
      return Stack(
        children: [
          Semantics(
            label: '首页列表',
            child: ListView.builder(
              key: const Key('home_list'),
              itemCount: list.length,
              itemBuilder: (context, index) {
                final item = list[index];
                return ListTile(
                  key: Key('list_item_$index'),
                  leading: CircleAvatar(child: Text('${item['id'] ?? index}')),
                  title: Text(item['title']?.toString() ?? '列表项 #$index'),
                  subtitle: Text(
                    item['subtitle']?.toString() ??
                        'Phase2 滑动性能测试 · item $index',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {},
                );
              },
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: Semantics(
              label: '刷新按钮',
              button: true,
              child: FloatingActionButton(
                key: const Key('refresh_button'),
                onPressed: controller.refreshList,
                child: const Icon(Icons.refresh),
              ),
            ),
          ),
        ],
      );
    });
  }
}
