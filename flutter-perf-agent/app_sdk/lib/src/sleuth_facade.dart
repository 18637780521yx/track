import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:sleuth/sleuth.dart';

/// Thin facade over Sleuth public APIs → [ApiResponse] envelopes.
class SleuthFacade {
  static ApiResponse<SleuthSnapshotData> snapshot({bool compact = false}) {
    if (kReleaseMode) {
      return ApiResponse.fail(ApiCodes.sleuthError, 'sleuth disabled in release');
    }
    try {
      if (compact) {
        final summary = Sleuth.exportSummary(topN: 10);
        return ApiResponse.ok(
          SleuthSnapshotData(kind: 'summary', markdown: summary),
        );
      }
      final jsonStr = Sleuth.exportSnapshotJson();
      if (jsonStr == null || jsonStr.isEmpty) {
        return ApiResponse.fail(
          ApiCodes.sleuthError,
          'exportSnapshotJson returned null — is Sleuth.track active?',
        );
      }
      final decoded = jsonDecode(jsonStr);
      return ApiResponse.ok(
        SleuthSnapshotData(kind: 'snapshot', snapshot: decoded),
      );
    } catch (e) {
      return ApiResponse.fail(ApiCodes.sleuthError, e.toString());
    }
  }

  static ApiResponse<SleuthSummaryData> summary({int topN = 5}) {
    if (kReleaseMode) {
      return ApiResponse.fail(ApiCodes.sleuthError, 'sleuth disabled in release');
    }
    try {
      final md = Sleuth.exportSummary(topN: topN);
      if (md == null) {
        return ApiResponse.fail(ApiCodes.sleuthError, 'exportSummary null');
      }
      return ApiResponse.ok(SleuthSummaryData(markdown: md));
    } catch (e) {
      return ApiResponse.fail(ApiCodes.sleuthError, e.toString());
    }
  }

  static ApiResponse<SleuthDiagnoseData> diagnose() {
    if (kReleaseMode) {
      return ApiResponse.fail(ApiCodes.sleuthError, 'sleuth disabled in release');
    }
    try {
      final d = Sleuth.diagnoseCaptureState();
      return ApiResponse.ok(
        SleuthDiagnoseData(
          initialized: d.initialized,
          captureMode: d.captureMode.toString(),
          vmConnected: d.vmConnected,
          advisory: d.vmConnected
              ? null
              : 'Sleuth VM link down — GC/heap/shader/heavy_compute detectors '
                  'may be silent. Relaunch with: flutter run --profile --no-dds',
        ),
      );
    } catch (e) {
      return ApiResponse.fail(ApiCodes.sleuthError, e.toString());
    }
  }

  static ApiResponse<SleuthIssuesData> issues({int limit = 50}) {
    if (kReleaseMode) {
      return ApiResponse.fail(ApiCodes.sleuthError, 'sleuth disabled in release');
    }
    try {
      final snap = Sleuth.exportSnapshot();
      if (snap == null) {
        return ApiResponse.fail(ApiCodes.sleuthError, 'no snapshot');
      }
      final list = <SleuthIssueItem>[];
      try {
        final dynamic d = snap;
        final raw = d.currentIssues as List? ?? d.issues as List?;
        if (raw != null) {
          for (final item in raw.take(limit)) {
            if (item is Map) {
              list.add(
                SleuthIssueItem.fromJson(Map<String, dynamic>.from(item)),
              );
            } else {
              list.add(_issueToItem(item));
            }
          }
        }
      } catch (_) {
        final jsonStr = Sleuth.exportSnapshotJson();
        if (jsonStr != null) {
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map) {
            final raw = decoded['currentIssues'] ?? decoded['issues'];
            if (raw is List) {
              for (final item in raw.take(limit)) {
                if (item is Map) {
                  list.add(
                    SleuthIssueItem.fromJson(Map<String, dynamic>.from(item)),
                  );
                } else {
                  list.add(SleuthIssueItem(detail: item.toString()));
                }
              }
            }
          }
        }
      }
      return ApiResponse.ok(SleuthIssuesData(count: list.length, issues: list));
    } catch (e) {
      return ApiResponse.fail(ApiCodes.sleuthError, e.toString());
    }
  }

  /// Time-to-first-frame and related startup metrics (needs [Sleuth.init]).
  static ApiResponse<StartupMetricsData> startup() {
    if (kReleaseMode) {
      return ApiResponse.fail(ApiCodes.sleuthError, 'sleuth disabled in release');
    }
    try {
      final m = Sleuth.startupMetrics;
      if (m == null) {
        return ApiResponse.ok(const StartupMetricsData());
      }
      return ApiResponse.ok(StartupMetricsData(metrics: m.toJson()));
    } catch (e) {
      return ApiResponse.fail(ApiCodes.sleuthError, e.toString());
    }
  }

  static ApiResponse<SleuthRouteHealthData> routeHealth({String? routeName}) {
    if (kReleaseMode) {
      return ApiResponse.fail(ApiCodes.sleuthError, 'sleuth disabled in release');
    }
    try {
      if (routeName != null && routeName.isNotEmpty) {
        return ApiResponse.ok(
          SleuthRouteHealthData(
            routeName: routeName,
            healthScore: Sleuth.routeHealthScore(routeName),
          ),
        );
      }
      final history = Sleuth.routeHistory;
      if (history == null) {
        return ApiResponse.fail(ApiCodes.sleuthError, 'no route history');
      }
      return ApiResponse.ok(
        SleuthRouteHealthData(
          routes: history
              .map(
                (s) => SleuthRouteEntry(
                  routeName: s.routeName,
                  healthScore: s.healthScore,
                  scaffoldHashKey: s.scaffoldHashKey?.toString(),
                  tabVisitIndex: s.tabVisitIndex,
                ),
              )
              .toList(),
        ),
      );
    } catch (e) {
      return ApiResponse.fail(ApiCodes.sleuthError, e.toString());
    }
  }

  static SleuthIssueItem _issueToItem(Object item) {
    try {
      final dynamic d = item;
      return SleuthIssueItem(
        stableId: _try(() => d.stableId?.toString()),
        id: _try(() => d.id?.toString()),
        title: _try(() => d.title?.toString() ?? d.message?.toString()),
        severity: _try(() => d.severity?.toString()),
        category: _try(() => d.category?.toString()),
        fixHint: _try(() => d.fixHint?.toString()),
        detail: _try(() => d.detail?.toString()) ?? item.toString(),
      );
    } catch (_) {
      return SleuthIssueItem(detail: item.toString());
    }
  }

  /// HTTP requests from Sleuth [NetworkMonitorDetector] ring buffer.
  ///
  /// When [sinceIso] is set, only records with `startedAt >= since` are returned
  /// (used to attribute requests to a single UI action window).
  static ApiResponse<NetworkRequestsData> networkRequests({
    String? sinceIso,
    int limit = 100,
  }) {
    if (kReleaseMode) {
      return ApiResponse.fail(ApiCodes.sleuthError, 'sleuth disabled in release');
    }
    try {
      final monitor = Sleuth.networkMonitor;
      if (monitor == null) {
        return ApiResponse.fail(
          ApiCodes.sleuthError,
          'networkMonitor unavailable — enableNetworkMonitoring?',
        );
      }
      DateTime? since;
      if (sinceIso != null && sinceIso.isNotEmpty) {
        since = DateTime.tryParse(sinceIso);
      }
      final out = <NetworkRequest>[];
      for (final r in monitor.records) {
        if (since != null && r.startedAt.isBefore(since)) continue;
        out.add(
          NetworkRequest(
            url: r.url,
            method: r.method,
            statusCode: r.statusCode,
            durationMs: r.durationMs,
            responseBytes: r.responseBytes,
            startedAt: r.startedAt.toIso8601String(),
            cancelled: r.cancelled,
            contentType: r.contentType,
            source: 'sleuth',
          ),
        );
      }
      // Newest last in ring; keep last [limit] for the window.
      final clipped = out.length > limit ? out.sublist(out.length - limit) : out;
      return ApiResponse.ok(
        NetworkRequestsData(requests: clipped, since: sinceIso),
      );
    } catch (e) {
      return ApiResponse.fail(ApiCodes.sleuthError, e.toString());
    }
  }

  static String? _try(Object? Function() f) {
    try {
      final v = f();
      return v?.toString();
    } catch (_) {
      return null;
    }
  }
}
