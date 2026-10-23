import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'network_capture.dart';
import 'session_journal.dart';
import 'sleuth_facade.dart';

/// D0m + D0s: Sleuth issue incremental → [AlertItem] on the journal.
///
/// Polls [SleuthFacade.issues]; emits when an allowlisted [stableId] appears
/// or its severity upgrades. When the issue leaves the current set, the
/// fingerprint is cleared so a later reappearance fires again.
///
/// Dedup key = raw stableId (so `excessive_keep_alive:A` ≠ `:B`).
/// [AlertItem.type] = canonical family when possible (`heap_growing`), else
/// the full stableId for instance-scoped structural hits.
class SleuthIssueLatch {
  SleuthIssueLatch._();
  static final SleuthIssueLatch instance = SleuthIssueLatch._();

  /// D0m memory-pressure families.
  static const memoryPressureIds = <String>{
    'gc_pressure',
    'heap_growing',
    'heap_near_capacity',
    'native_memory_growing',
  };

  /// D0s runtime / VM detectors (PRD §6.1).
  static const runtimeIds = <String>{
    'shader_compilation',
    'heavy_compute',
    'platform_channel_traffic',
    'stream_resource_growth',
    'rebuild_activity',
    'excessive_repaint',
    'sustained_jank',
    'raster_dominance',
    'expensive_gpu_nodes',
    'raster_cache_thrashing',
    'raster_cache_growing',
    'stateful_density',
  };

  /// D0s#9 Widget tree structural scan.
  static const structuralIds = <String>{
    'missing_repaint_boundary',
    'excessive_repaint_boundary',
    'layout_bottleneck',
    'wrap_layout_bottleneck',
    'non_lazy_list',
    'non_lazy_shrinkwrap',
    'sliver_to_box_adapter_large',
    'sliver_fill_remaining_scrollable',
    'sliver_to_box_adapter_shrinkwrap',
    'setstate_scope',
    'excessive_keep_alive', // prefix: excessive_keep_alive:<suffix>
    'always_repaint_painter',
    'frequent_repaint_painter',
    'uncached_images',
    'runtime_font_loading',
    'multiple_custom_fonts',
  };

  /// Network (升一等；与账本 network 事件并存).
  static const networkIds = <String>{
    'slow_request',
    'large_response',
    'request_frequency',
    'http_error_spike',
    'high_frequency_same_path', // prefix
  };

  /// Covered by [FrameJankLatch] — do not double-emit.
  static const excludedIds = <String>{
    'jank_detected',
  };

  /// Default allowlist = D0m + D0s (+ network).
  static Set<String> get defaultAllowlist => {
        ...memoryPressureIds,
        ...runtimeIds,
        ...structuralIds,
        ...networkIds,
      };

  /// Active allowlist (mutable).
  Set<String> allowlist = defaultAllowlist;

  Duration pollInterval = const Duration(milliseconds: 500);

  Timer? _timer;
  bool _started = false;

  /// rawStableId → last severity key.
  final Map<String, String> _emittedSeverity = {};

  DateTime? _liveWriteAt;
  static const _liveWriteMinGap = Duration(milliseconds: 800);

  void ensureStarted() {
    if (kReleaseMode || _started) return;
    _started = true;
    _timer = Timer.periodic(pollInterval, (_) => _poll());
    debugPrint(
      '[SleuthIssueLatch] started '
      '(poll=${pollInterval.inMilliseconds}ms ids=${allowlist.length})',
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
    _emittedSeverity.clear();
  }

  void onSessionStart() {
    _emittedSeverity.clear();
    for (final item in _pollAllowlisted()) {
      final raw = _rawId(item);
      if (raw == null) continue;
      _emittedSeverity[raw] = _severityKey(item);
    }
    debugPrint(
      '[SleuthIssueLatch] session seed ${_emittedSeverity.length} issues',
    );
  }

  void onSessionEnd() {
    _emittedSeverity.clear();
  }

  void _poll() {
    if (!SessionJournal.instance.isActive) return;
    final items = _pollAllowlisted();
    final present = <String>{};
    var wrote = false;

    for (final item in items) {
      final raw = _rawId(item);
      final alertType = _alertTypeFor(item);
      if (raw == null || alertType == null) continue;
      present.add(raw);
      final sev = _severityKey(item);
      final prev = _emittedSeverity[raw];
      if (prev == sev) continue;
      final upgraded = prev != null && _severityRank(sev) > _severityRank(prev);
      if (prev != null && !upgraded) {
        _emittedSeverity[raw] = sev;
        continue;
      }
      _emittedSeverity[raw] = sev;
      _emit(item, alertType: alertType, rawId: raw, upgraded: upgraded);
      wrote = true;
    }

    _emittedSeverity.removeWhere((k, _) => !present.contains(k));

    if (wrote) _maybeWriteLive();
  }

  List<SleuthIssueItem> _pollAllowlisted() {
    try {
      final res = SleuthFacade.issues(limit: 80);
      if (!res.isOk || res.data == null) return const [];
      return [
        for (final i in res.data!.issues)
          if (_alertTypeFor(i) != null) i,
      ];
    } catch (e) {
      debugPrint('[SleuthIssueLatch] poll failed: $e');
      return const [];
    }
  }

  String? _rawId(SleuthIssueItem item) {
    final id = (item.stableId ?? item.id ?? '').trim();
    if (id.isNotEmpty) return id;
    return _alertTypeFor(item);
  }

  /// Returns canonical [AlertItem.type], or null if not allowlisted / excluded.
  String? _alertTypeFor(SleuthIssueItem item) {
    final id = (item.stableId ?? item.id ?? '').trim();
    if (id.isNotEmpty) {
      if (excludedIds.contains(id)) return null;
      if (allowlist.contains(id)) return id;
      for (final needle in allowlist) {
        if (id.startsWith('$needle:')) return id; // instance-scoped
        if (id.startsWith('$needle.')) return needle; // severity/tier suffix
        // Avoid false positive: needle_xxx only when needle is a true prefix
        // family (e.g. we do not treat rebuild_debug as rebuild_activity).
      }
      // high_frequency_same_path:<fp>
      if (id.startsWith('high_frequency_same_path:')) {
        return allowlist.contains('high_frequency_same_path') ? id : null;
      }
      if (id.startsWith('excessive_keep_alive:')) {
        return allowlist.contains('excessive_keep_alive') ? id : null;
      }
      return null;
    }
    // Title fallback.
    final title = (item.title ?? item.detail ?? '').toLowerCase();
    for (final needle in allowlist) {
      if (excludedIds.contains(needle)) continue;
      if (title.contains(needle) ||
          title.contains(needle.replaceAll('_', ' '))) {
        return needle;
      }
    }
    return null;
  }

  static String _severityKey(SleuthIssueItem item) {
    return (item.severity ?? '').toLowerCase().trim();
  }

  static int _severityRank(String sev) {
    if (sev.contains('critical') || sev.contains('error')) return 3;
    if (sev.contains('warning')) return 2;
    if (sev.contains('info')) return 1;
    return 0;
  }

  static bool _isMemory(String type) => memoryPressureIds.contains(type);

  void _emit(
    SleuthIssueItem item, {
    required String alertType,
    required String rawId,
    required bool upgraded,
  }) {
    final title = item.title ?? item.detail ?? alertType;
    final sev = item.severity;
    final kind = _isMemory(alertType.split(':').first)
        ? '内存压力'
        : 'Sleuth';
    final msg = upgraded
        ? '$kind升级：$title${sev != null ? ' ($sev)' : ''}'
        : '$kind：$title${sev != null ? ' ($sev)' : ''}';
    final value = <String, dynamic>{
      'stableId': rawId,
      if (item.title != null) 'title': item.title,
      if (item.severity != null) 'severity': item.severity,
      if (item.category != null) 'category': item.category,
      if (item.fixHint != null) 'fixHint': item.fixHint,
      if (item.detail != null) 'detail': item.detail,
      'source': 'sleuth_issue_latch',
    };
    final raw = item.raw;
    if (raw != null) {
      for (final k in [
        'bytesPerSecond',
        'heapBytes',
        'rssBytes',
        'usageRatio',
        'gcCount',
        'gcPerMinute',
        'message',
        'observationSource',
        'routeName',
      ]) {
        if (raw[k] != null) value[k] = raw[k];
      }
    }

    SessionJournal.instance.appendRealtimeAlert(
      AlertItem(
        type: alertType,
        stepId: '',
        action: 'sleuth:$alertType',
        message: msg,
        value: value,
        at: DateTime.now().toIso8601String(),
      ),
      routeHint: PerfNetworkCapture.currentRoute(),
    );
  }

  void _maybeWriteLive() {
    final now = DateTime.now();
    final last = _liveWriteAt;
    if (last != null && now.difference(last) < _liveWriteMinGap) return;
    _liveWriteAt = now;
    unawaited(SessionJournal.instance.writeLiveReport());
  }
}
