import 'package:flutter/material.dart';

/// Middle tab: light content for tab-switch + scroll smoke.
class DiscoverTab extends StatelessWidget {
  const DiscoverTab({super.key});

  static const _topics = <(String, String, IconData)>[
    ('性能巡检', 'Sleuth 帧耗时 / jank 追踪', Icons.speed),
    ('网络抓包', '请求头与 body 写入报告', Icons.cloud_sync_outlined),
    ('列表滑动', '首页长列表压测', Icons.view_list_outlined),
    ('个人中心', '头像上传与昵称修改', Icons.person_outline),
    ('GetX 路由', 'Binding + Controllers', Icons.route),
    ('Bridge', 'PerfBridge 127.0.0.1:19288', Icons.cable),
  ];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '发现列表',
      child: ListView.separated(
        key: const Key('discover_list'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _topics.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final (title, subtitle, icon) = _topics[index];
          return ListTile(
            key: Key('discover_item_$index'),
            leading: CircleAvatar(child: Icon(icon, size: 20)),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          );
        },
      ),
    );
  }
}
