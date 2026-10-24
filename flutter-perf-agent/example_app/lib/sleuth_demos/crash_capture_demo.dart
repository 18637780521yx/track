import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_perf_agent/flutter_perf_agent.dart';

import 'demo_scaffold.dart';

/// Trigger D1 `alertType=crash` for the three capture kinds.
///
/// Requires an **active** session (banner「开始」or MCP `start_perf_test`).
class CrashCaptureDemo extends StatefulWidget {
  const CrashCaptureDemo({super.key});

  @override
  State<CrashCaptureDemo> createState() => _CrashCaptureDemoState();
}

class _CrashCaptureDemoState extends State<CrashCaptureDemo> {
  String? _lastAction;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Refresh session-active hint while on this page.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool get _sessionOn => SessionJournal.instance.isActive;

  void _note(String msg) {
    setState(() => _lastAction = msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// → CrashCapture kind=`flutter_error`
  void _triggerFlutterError() {
    if (!_sessionOn) {
      _note('请先开会话（顶部横幅「开始」或 MCP start_perf_test）');
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: Exception('demo FlutterError (crash kind=flutter_error)'),
        stack: StackTrace.current,
        library: 'crash_capture_demo',
        context: ErrorDescription('triggered from CrashCaptureDemo button'),
      ),
    );
    _note('已触发 flutter_error → 看报告 alertType=crash');
  }

  /// → runZonedGuarded → CrashCapture kind=`zone`
  void _triggerZone() {
    if (!_sessionOn) {
      _note('请先开会话（顶部横幅「开始」或 MCP start_perf_test）');
      return;
    }
    // Unawaited future error is handled by main's runZonedGuarded.
    Future<void>.delayed(Duration.zero, () {
      throw Exception('demo Zone error (crash kind=zone)');
    });
    _note('已抛 Zone 异步异常 → 看报告 alertType=crash kind=zone');
  }

  /// → CrashCapture kind=`uncaught`（与 PlatformDispatcher 钩子同写入路径）
  ///
  /// Under [runZonedGuarded], most Dart throws become `zone` first, so this
  /// button writes `uncaught` the same way [PlatformDispatcher.onError] does.
  void _triggerUncaught() {
    if (!_sessionOn) {
      _note('请先开会话（顶部横幅「开始」或 MCP start_perf_test）');
      return;
    }
    CrashCapture.instance.report(
      Exception('demo PlatformDispatcher uncaught (crash kind=uncaught)'),
      StackTrace.current,
      kind: 'uncaught',
      fatal: true,
    );
    _note('已写入 uncaught → 看报告 alertType=crash kind=uncaught');
  }

  @override
  Widget build(BuildContext context) {
    final sessionHint = _sessionOn
        ? '会话进行中 · 触发后结束会话看带时间戳的 HTML 终稿'
        : '⚠ 尚无会话 — 请先点 App 顶栏「开始」或 MCP start_perf_test';

    return DemoScaffold(
      title: 'Crash 异常三连',
      description: 'Bad: 触发 FlutterError / Zone / uncaught，写入 alertType=crash。\n'
          'Fix: 生产环境应上报后收敛；此处仅用于验收报告时间线。\n'
          '试：开会话 → 依次点三个按钮 → 看 live 报告。',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: _sessionOn
                ? const Color(0xFFE3F5EE)
                : const Color(0xFFFFF1F0),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                sessionHint,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _sessionOn
                      ? const Color(0xFF0B6E4F)
                      : const Color(0xFFB42318),
                ),
              ),
            ),
          ),
          if (_lastAction != null) ...[
            const SizedBox(height: 8),
            Text(
              '最近：$_lastAction',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          _CrashButton(
            key: const Key('crash_flutter_error_button'),
            title: '1 · FlutterError',
            subtitle: 'kind=flutter_error · FlutterError.reportError',
            color: Colors.deepOrange,
            onPressed: _triggerFlutterError,
          ),
          const SizedBox(height: 10),
          _CrashButton(
            key: const Key('crash_zone_button'),
            title: '2 · Zone 未捕获',
            subtitle: 'kind=zone · Future 抛错 → runZonedGuarded',
            color: Colors.indigo,
            onPressed: _triggerZone,
          ),
          const SizedBox(height: 10),
          _CrashButton(
            key: const Key('crash_uncaught_button'),
            title: '3 · PlatformDispatcher uncaught',
            subtitle: 'kind=uncaught · 与 onError 钩子同路径写入',
            color: Colors.red.shade700,
            onPressed: _triggerUncaught,
          ),
          const SizedBox(height: 24),
          Text(
            '报告里应出现 3 条 type=alert / alertType=crash，'
            'value.kind 分别为 flutter_error、zone、uncaught。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _CrashButton extends StatelessWidget {
  const _CrashButton({
    super.key,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onPressed,
  });

  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: FilledButton.tonal(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.12),
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          alignment: Alignment.centerLeft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: color.withValues(alpha: 0.85),
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
