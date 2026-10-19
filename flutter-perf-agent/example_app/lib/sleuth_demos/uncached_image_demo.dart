import 'package:flutter/material.dart';

import 'demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 13: Uncached Images
// Triggers: ImageMemory detector
// ─────────────────────────────────────────

/// Demonstrates decoding network images at full resolution instead of at
/// display size. A 800×800 JPEG decoded into a 120×120 grid tile wastes
/// ~2 MB per image. The fix uses `cacheWidth` / `cacheHeight` to decode
/// the image at its display size.
class UncachedImageDemo extends StatelessWidget {
  const UncachedImageDemo({super.key});

  static const _itemCount = 12;

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: '未缓存图片',
      description:
                    '问题：Image.network 未设 cacheWidth/cacheHeight，解码全尺寸图占内存。\n'
          '修复：按显示尺寸设置缓存宽高，或使用带缓存的图片库。\n\n'
          '滚动图库，观察 ImageMemory / uncached_images。',
      body: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: _itemCount,
        itemBuilder: (_, i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          // ❌ No cacheWidth — full 800×800 decoded into memory
          child: Image.network(
            'https://picsum.photos/seed/$i/800/800',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: Color(0xFFE0E0E0),
              child: Center(child: Icon(Icons.broken_image)),
            ),
          ),
        ),
      ),
      fixedBody: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: _itemCount,
        itemBuilder: (_, i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          // ✅ cacheWidth matches display size (2x for high-DPI screens)
          child: Image.network(
            'https://picsum.photos/seed/$i/800/800',
            fit: BoxFit.cover,
            cacheWidth: 240,
            cacheHeight: 240,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: Color(0xFFE0E0E0),
              child: Center(child: Icon(Icons.broken_image)),
            ),
          ),
        ),
      ),
    );
  }
}
