import 'package:flutter/material.dart';

import 'demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 12: IntrinsicHeight Abuse
// Triggers: LayoutBottleneck detector
// ─────────────────────────────────────────

/// Demonstrates the cost of `IntrinsicHeight`, which causes O(n²) layout
/// passes. The fix uses `CrossAxisAlignment.stretch` on an ordinary Row,
/// which lets each row's children share a naturally-computed height.
class IntrinsicHeightDemo extends StatelessWidget {
  const IntrinsicHeightDemo({super.key});

  static const _rowCount = 8;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: '滥用 IntrinsicHeight',
      description:
                    '问题：用 IntrinsicHeight 包 Row 会强制两次布局，列表越大越慢。\n'
          '修复：改用固定高度、Align、或自定义布局避免 intrinsic 测量。\n\n'
          '滚动并观察 LayoutBottleneck 相关 issue。',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (var i = 0; i < _rowCount; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                // ❌ IntrinsicHeight — slow two-pass layout
                child: IntrinsicHeight(child: _RowCells(index: i)),
              ),
          ],
        ),
      ),
      fixedBody: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (var i = 0; i < _rowCount; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                // ✅ Plain Row with CrossAxisAlignment.stretch — single pass
                child: _RowCells(index: i, stretch: true),
              ),
          ],
        ),
      ),
    );
  }
}

class _RowCells extends StatelessWidget {
  const _RowCells({required this.index, this.stretch = false});

  final int index;
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: stretch
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.center,
      children: [
        Expanded(
          child: ColoredBox(
            color: Colors.blue.withValues(alpha: 0.1 + index * 0.05),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Left cell $index\nMulti-line\ncontent'),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ColoredBox(
            color: Colors.red.withValues(alpha: 0.1 + index * 0.05),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Right $index\n${"Extra line\n" * index}'),
            ),
          ),
        ),
      ],
    );
  }
}
