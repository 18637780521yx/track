import 'package:flutter/material.dart';

/// Discover tab: 说明本 demo 的检测入口（不再内嵌 Sleuth 场景）。
class DiscoverTab extends StatelessWidget {
  const DiscoverTab({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '发现页',
      child: ListView(
        key: const Key('discover_list'),
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Fast Track MCP',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Crash / ANR / jank / 内存由 App SDK detect 写入 SessionJournal；'
            '可在「我的」触发 FlutterError、泄漏 Dialog 等演示。',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
