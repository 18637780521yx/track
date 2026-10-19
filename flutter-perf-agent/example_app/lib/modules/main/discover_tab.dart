import 'package:flutter/material.dart';

import '../../sleuth_demos/sleuth_demo_catalog.dart';

/// Discover tab: Sleuth official example scenario catalog.
class DiscoverTab extends StatelessWidget {
  const DiscoverTab({super.key});

  @override
  Widget build(BuildContext context) {
    final categories = sleuthDemoCategories();
    return Semantics(
      label: 'Sleuth 场景目录',
      child: ListView.builder(
        key: const Key('discover_list'),
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: categories.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '以下为 Sleuth 官方示例场景（中文）。点进详情页可触发对应检测；'
                'GC / Shader 等请用 flutter run --profile --no-dds。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            );
          }
          final cat = categories[index - 1];
          return _CategorySection(category: cat);
        },
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({required this.category});

  final SleuthDemoCategory category;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(category.icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                category.title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${category.demos.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ...category.demos.map((demo) {
          return ListTile(
            key: Key('sleuth_demo_${demo.slug}'),
            leading: CircleAvatar(
              backgroundColor: demo.color.withValues(alpha: 0.15),
              child: Icon(demo.icon, color: demo.color, size: 20),
            ),
            title: Text(demo.title),
            subtitle: Text(demo.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => pushSleuthDemo(context, demo),
          );
        }),
      ],
    );
  }
}
