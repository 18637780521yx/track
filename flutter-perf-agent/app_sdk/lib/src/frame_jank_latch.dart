import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:sleuth/sleuth.dart';

import 'network_capture.dart';
import 'session_journal.dart';

/// D0: Sleuth jank capture → one-shot [AlertItem] on the active journal step.
///
/// Sleuth does not export [SleuthController.verdictNotifier]; we poll
/// [Sleuth.exportSnapshot].capturedFrames (worst-jank buffer with
/// [FrameVerdict]). Historical frames present at session start are seeded
/// as already-seen so we only emit frames that land during the session.
class FrameJankLatch {
  FrameJankLatch._();
  static final FrameJankLatch instance = FrameJankLatch._();

  /// Frame budget (ms). Used for message text; Sleuth already classified jank.
  double maxFrameCostMs = 16;

  Duration pollInterval = const Duration(milliseconds: 400);

  Timer? _timer;
  bool _started = false;

  /// frameNumber → last verdict fingerprint (for topFunctions upgrades).
  final Map<int, String> _seenFp = {};

  DateTime? _liveWriteAt;
  static const _liveWriteMinGap = Duration(milliseconds: 800);

  void ensureStarted() {
    if (kReleaseMode || _started) return;
    _started = true;
    _timer = Timer.periodic(pollInterval, (_) => _poll());
    debugPrint('[FrameJankLatch] started (poll=${pollInterval.inMilliseconds}ms)');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
    _seenFp.clear();
  }

  /// Call from [SessionJournal.start] — ignore frames already in the buffer.
  void onSessionStart() {
    _seenFp.clear();
    try {
      final snap = Sleuth.exportSnapshot();
      final frames = snap?.capturedFrames ?? const <CaptureEntry>[];
      for (final e in frames) {
        final n = e.frameStats.frameNumber;
        _seenFp[n] = _verdictFp(e);
      }
      debugPrint(
        '[FrameJankLatch] session seed ${_seenFp.length} prior frames',
      );
    } catch (e) {
      debugPrint('[FrameJankLatch] seed failed: $e');
    }
  }

  void onSessionEnd() {
    _seenFp.clear();
  }

  void _poll() {
    if (!SessionJournal.instance.isActive) return;
    List<CaptureEntry> entries;
    try {
      entries = Sleuth.exportSnapshot()?.capturedFrames ?? const [];
    } catch (_) {
      return;
    }
    if (entries.isEmpty) return;

    var wrote = false;
    for (final entry in entries) {
      final n = entry.frameStats.frameNumber;
      final fp = _verdictFp(entry);
      final prev = _seenFp[n];
      if (prev == fp) continue;
      _seenFp[n] = fp;
      if (prev == null) {
        _emitNew(entry);
        wrote = true;
      } else {
        _upgradeExisting(entry);
        wrote = true;
      }
    }
    if (wrote) _maybeWriteLive();
  }

  String _verdictFp(CaptureEntry e) {
    final v = e.verdict;
    final top = v.topFunctions;
    final topN = top == null ? 0 : top.length;
    return '${v.suspectedPhase.name}|${v.isCorrelated}|${v.isFullMode}|$topN|'
        '${v.reason.hashCode}|${e.relatedIssues.length}';
  }

  void _emitNew(CaptureEntry entry) {
    final journal = SessionJournal.instance;
    if (!journal.isActive) return;

    final v = entry.verdict;
    final frameMs = v.totalFrameTime.inMicroseconds / 1000.0;
    final budgetMs = entry.frameStats.frameBudgetMs.toDouble();
    final severe = entry.frameStats.isSevereJank;
    final alertType = severe ? 'slow_frame' : 'jank';
    final route = PerfNetworkCapture.currentRoute();
    final at = entry.capturedAt.toIso8601String();
    final value = _valueMap(entry, frameMs: frameMs, budgetMs: budgetMs);
    final phase = v.suspectedPhase.name;
    final msg = severe
        ? '严重卡顿 ${frameMs.toStringAsFixed(1)}ms '
            '(预算 ${budgetMs.toStringAsFixed(0)}ms)×'
            '${FrameStats.severeJankBudgetMultiplier}'
            '${v.isFullMode || v.isCorrelated ? ' · $phase' : ''}'
        : '卡顿 ${frameMs.toStringAsFixed(1)}ms'
            '${v.isFullMode || v.isCorrelated ? ' · 疑似$phase' : ''}';

    journal.appendRealtimeAlert(
      AlertItem(
        type: alertType,
        stepId: '', // filled by journal
        action: 'frame_jank',
        message: msg,
        value: value,
        threshold: budgetMs,
        at: at,
      ),
      routeHint: route,
    );
  }

  void _upgradeExisting(CaptureEntry entry) {
    final journal = SessionJournal.instance;
    if (!journal.isActive) return;
    final frameMs = entry.verdict.totalFrameTime.inMicroseconds / 1000.0;
    final budgetMs = entry.frameStats.frameBudgetMs.toDouble();
    final value = _valueMap(entry, frameMs: frameMs, budgetMs: budgetMs);
    final n = entry.frameStats.frameNumber;
    journal.upgradeRealtimeFrameAlert(
      frameNumber: n,
      value: value,
    );
  }

  Map<String, dynamic> _valueMap(
    CaptureEntry entry, {
    required double frameMs,
    required double budgetMs,
  }) {
    final v = entry.verdict;
    final vmMode = v.isCorrelated
        ? 'correlated'
        : (v.isFullMode ? 'full' : 'basic');
    final related = entry.relatedIssues.isNotEmpty
        ? entry.relatedIssues
        : v.relatedIssues;
    return <String, dynamic>{
      'frameNumber': entry.frameStats.frameNumber,
      'frameMs': double.parse(frameMs.toStringAsFixed(2)),
      'uiMs': double.parse(
        (v.uiThreadTime.inMicroseconds / 1000.0).toStringAsFixed(2),
      ),
      'rasterMs': double.parse(
        (v.rasterThreadTime.inMicroseconds / 1000.0).toStringAsFixed(2),
      ),
      if (v.buildScopeTime != null)
        'buildMs': double.parse(
          (v.buildScopeTime!.inMicroseconds / 1000.0).toStringAsFixed(2),
        ),
      if (v.flushLayoutTime != null)
        'layoutMs': double.parse(
          (v.flushLayoutTime!.inMicroseconds / 1000.0).toStringAsFixed(2),
        ),
      if (v.flushPaintTime != null)
        'paintMs': double.parse(
          (v.flushPaintTime!.inMicroseconds / 1000.0).toStringAsFixed(2),
        ),
      'suspectedPhase': v.suspectedPhase.name,
      'reason': v.reason,
      'vmMode': vmMode,
      'budgetMs': budgetMs,
      if (related.isNotEmpty)
        'relatedIssues': related.take(6).map(_issueShort).toList(),
      if (v.topFunctions != null && v.topFunctions!.isNotEmpty)
        'topFunctions': v.topFunctions!.take(5).map((f) => f.toJson()).toList(),
      if (v.pendingRequestCount != null)
        'pendingRequestCount': v.pendingRequestCount,
      if (v.slowestPendingMs != null) 'slowestPendingMs': v.slowestPendingMs,
    };
  }

  static Map<String, dynamic> _issueShort(PerformanceIssue i) {
    final j = i.toJson();
    return <String, dynamic>{
      if (j['stableId'] != null) 'stableId': j['stableId'],
      if (j['title'] != null) 'title': j['title'],
      if (j['severity'] != null) 'severity': j['severity'],
      if (j['category'] != null) 'category': j['category'],
      if (j['fixHint'] != null) 'fixHint': j['fixHint'],
      if (j['routeName'] != null) 'routeName': j['routeName'],
    };
  }

  void _maybeWriteLive() {
    final now = DateTime.now();
    final last = _liveWriteAt;
    if (last != null && now.difference(last) < _liveWriteMinGap) return;
    _liveWriteAt = now;
    unawaited(SessionJournal.instance.writeLiveReport());
  }
}
