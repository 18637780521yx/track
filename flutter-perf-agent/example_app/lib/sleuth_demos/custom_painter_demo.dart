import 'package:flutter/material.dart';

import 'demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 7: Always-Repaint CustomPainter
// Triggers: CustomPainter detector
// ─────────────────────────────────────────

/// Demonstrates a `CustomPainter` whose `shouldRepaint` always returns
/// `true`. Flutter can't skip the paint phase, so the canvas redraws on
/// every frame even when nothing changed. The fix compares the new
/// `progress` against the old one.
class CustomPainterDemo extends StatefulWidget {
  const CustomPainterDemo({super.key});

  @override
  State<CustomPainterDemo> createState() => _CustomPainterDemoState();
}

class _CustomPainterDemoState extends State<CustomPainterDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Always-Repaint 画笔',
      description:
                    '问题：shouldRepaint 永远返回 true，Flutter 无法跳过绘制。\n'
          '修复：仅在数据真正变化时返回 true。\n\n'
          '切换模式后观察 CustomPainter 相关检测。',
      body: AnimatedBuilder(
        animation: _anim,
        builder: (_, _) => CustomPaint(
          painter: _BadCirclePainter(_anim.value),
          size: Size.infinite,
        ),
      ),
      fixedBody: AnimatedBuilder(
        animation: _anim,
        builder: (_, _) => CustomPaint(
          painter: _GoodCirclePainter(_anim.value),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BadCirclePainter extends CustomPainter {
  _BadCirclePainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color.lerp(Colors.blue, Colors.purple, progress)!
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      50 + progress * 80,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true; // ❌ Always
}

class _GoodCirclePainter extends CustomPainter {
  _GoodCirclePainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color.lerp(Colors.green, Colors.teal, progress)!
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      50 + progress * 80,
      paint,
    );
  }

  @override
  // ✅ Only repaint when progress actually changed
  bool shouldRepaint(covariant _GoodCirclePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
