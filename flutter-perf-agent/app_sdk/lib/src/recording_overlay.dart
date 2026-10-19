import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'session_journal.dart';

/// Small banner: show when a session is active; stop writes SDK report.
class PerfRecordingBanner extends StatefulWidget {
  const PerfRecordingBanner({super.key, this.child});

  final Widget? child;

  @override
  State<PerfRecordingBanner> createState() => _PerfRecordingBannerState();
}

class _PerfRecordingBannerState extends State<PerfRecordingBanner> {
  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) return widget.child ?? const SizedBox.shrink();

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          if (widget.child != null) widget.child!,
          Positioned(
            left: 12,
            right: 12,
            top: 8,
            child: SafeArea(
              child: AnimatedBuilder(
                animation: _Ticker.instance,
                builder: (context, _) {
                  final j = SessionJournal.instance;
                  if (!j.isActive) return const SizedBox.shrink();
                  return Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(10),
                    color: const Color(0xFF0B6E4F),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.fiber_manual_record,
                              color: Colors.redAccent, size: 14),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '录制中 · ${j.testName ?? ""} · ${j.steps.length} 步',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              final paths = await SessionJournal.instance
                                  .stopAndWriteReport();
                              if (!context.mounted) return;
                              final msg = paths == null
                                  ? '无报告'
                                  : '已生成:\n${paths.jsonPath}';
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(content: Text(msg)),
                              );
                              setState(() {});
                            },
                            child: const Text(
                              '结束',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cheap 1s tick so the banner refreshes step counts.
class _Ticker extends ChangeNotifier {
  _Ticker._() {
    Stream<void>.periodic(const Duration(seconds: 1)).listen((_) {
      notifyListeners();
    });
  }
  static final instance = _Ticker._();
}
