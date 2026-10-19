import 'package:flutter/material.dart';

import 'custom_detectors/01_simple_structural_detector.dart';
import 'custom_detectors/02_runtime_callback_detector.dart';
import 'custom_detectors/03_hybrid_vm_structural_detector.dart';

/// Demo page that exercises every detector in `example/lib/custom_detectors/`.
///
/// This screen is a runtime showcase for the cookbook. The custom detectors
/// are passed to `Sleuth.track` in `main.dart`, so they're already attached
/// to the overlay when this screen appears. All the demo has to do is
/// construct widget shapes that make each detector fire:
///
/// - [TooltipUsageDetector] (`01`): a Tooltip at the top of the tree.
/// - [SlowFrameDetector] (`02`): a button that deliberately blocks the UI
///   thread for 80 ms on tap, producing a slow frame.
/// - [RasterHotSpotDetector] (`03`): a wide Stack subtree with 10 layers.
///
/// Open the Sleuth overlay after interacting with the page and each
/// cookbook detector should show at least one entry in the issue list.
class CustomDetectorCookbookDemo extends StatelessWidget {
  const CustomDetectorCookbookDemo({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('自定义 Detector 教程')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '本页对接 cookbook 里的三个自定义 detector。每个卡片触发一类问题；'
            '操作后打开 Sleuth 浮层即可看到对应 issue。',
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          const _CookbookCard(
            number: '01',
            title: 'Tooltip 使用检测',
            subtitle: '结构型检测：扫描树并按匹配项发出 issue。',
            body: Tooltip(
              message: '此 Tooltip 会触发 cookbook detector 01',
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '长按本行查看 Tooltip；每次扫描都会计数。',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _CookbookCard(
            number: '02',
            title: '慢帧检测',
            subtitle: '运行时检测：监听帧回调，报告超过 32ms 的帧。',
            body: _SlowFrameTrigger(),
          ),
          const SizedBox(height: 16),
          const _CookbookCard(
            number: '03',
            title: 'Raster 热点检测',
            subtitle: '混合检测：VM raster 超预算时统计过宽 Stack。',
            body: _WideStackExample(),
          ),
          const SizedBox(height: 24),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '三个 detector 都注册了稳定 key。可在 SleuthConfig 里禁用，'
                '无需删实例：\n\n'
                "disabledCustomDetectorKeys: {'tooltip_usage'}",
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onPrimaryContainer,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CookbookCard extends StatelessWidget {
  const _CookbookCard({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.body,
  });

  final String number;
  final String title;
  final String subtitle;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      number,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            body,
          ],
        ),
      ),
    );
  }
}

class _SlowFrameTrigger extends StatefulWidget {
  const _SlowFrameTrigger();

  @override
  State<_SlowFrameTrigger> createState() => _SlowFrameTriggerState();
}

class _SlowFrameTriggerState extends State<_SlowFrameTrigger> {
  int _taps = 0;

  void _blockUiThread() {
    // Burn ~80 ms of CPU on the UI thread. This is well above the
    // default 32 ms threshold in SlowFrameDetector, so the next frame
    // measurement will flag it.
    final deadline = DateTime.now().add(const Duration(milliseconds: 80));
    var counter = 0;
    while (DateTime.now().isBefore(deadline)) {
      counter++;
    }
    if (!mounted) return;
    setState(() {
      _taps++;
    });
    debugPrint('slow-frame trigger: burned $counter loop iterations');
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        FilledButton.icon(
          onPressed: _blockUiThread,
          icon: const Icon(Icons.bolt),
          label: const Text('触发慢帧'),
        ),
        const SizedBox(width: 12),
        Text('点击次数: $_taps'),
      ],
    );
  }
}

class _WideStackExample extends StatelessWidget {
  const _WideStackExample();

  @override
  Widget build(BuildContext context) {
    // 10 stacked layers exceed RasterHotSpotDetector's default
    // stackChildLimit of 8. They're all simple coloured boxes so the
    // cost is visual, not computational — the point is to build the
    // structural shape the detector is looking for.
    return SizedBox(
      height: 120,
      child: Stack(
        children: [
          for (int i = 0; i < 10; i++)
            Positioned(
              left: (i * 12).toDouble(),
              top: (i * 6).toDouble(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.primaries[i % Colors.primaries.length]
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const SizedBox(width: 60, height: 60),
              ),
            ),
        ],
      ),
    );
  }
}
