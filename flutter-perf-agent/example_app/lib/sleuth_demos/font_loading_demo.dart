import 'package:flutter/material.dart';

import 'demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 20: Font Loading Stress
// Triggers: FontLoading detector (>3 custom fonts)
// ─────────────────────────────────────────

/// Demonstrates loading many custom font families on a single screen.
/// Each family triggers a separate font load and increases binary size,
/// memory, and first-paint jank.
class FontLoadingDemo extends StatelessWidget {
  const FontLoadingDemo({super.key});

  // ❌ 7 distinct custom font families — triggers threshold of >3 with
  // a defensive margin. If FontLoadingDetector.fontLoadingMaxFamilies ever
  // gets raised to catch fewer false positives, this demo keeps firing.
  static const _badFonts = [
    'Lobster',
    'Pacifico',
    'DancingScript',
    'IndieFlower',
    'GreatVibes',
    'PermanentMarker',
    'Caveat',
  ];

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: '字体加载压力',
      description:
                    '问题：单页使用 ${_badFonts.length} 种自定义字体，增加加载与首绘成本。\n'
          '修复：限制 1～2 个字族，用字重/字号变化；必要字体启动时预加载。\n\n'
          '切换错误/正确模式，观察 FontLoading 检测。',
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final font in _badFonts)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      font,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'The quick brown fox jumps over the lazy dog',
                      style: TextStyle(fontFamily: font, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      fixedBody: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [
          _FixedRow(label: 'Default w400', weight: FontWeight.w400),
          _FixedRow(label: 'Default w500', weight: FontWeight.w500),
          _FixedRow(label: 'Default w600', weight: FontWeight.w600),
          _FixedRow(label: 'Default w700', weight: FontWeight.w700),
          _FixedRow(label: 'Default w800', weight: FontWeight.w800),
        ],
      ),
    );
  }
}

class _FixedRow extends StatelessWidget {
  const _FixedRow({required this.label, required this.weight});

  final String label;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              'The quick brown fox jumps over the lazy dog',
              style: TextStyle(fontSize: 16, fontWeight: weight),
            ),
          ),
        ],
      ),
    );
  }
}
