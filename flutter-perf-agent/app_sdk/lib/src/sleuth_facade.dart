import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sleuth/sleuth.dart';

/// Thin facade over Sleuth's public export / diagnose APIs for the HTTP bridge.
class SleuthFacade {
  /// Full session snapshot (frames, issues, causal edges, heat map, routes…).
  static Map<String, dynamic> snapshot({bool compact = false}) {
    if (kReleaseMode) {
      return {'ok': false, 'error': 'sleuth disabled in release'};
    }
    try {
      if (compact) {
        final summary = Sleuth.exportSummary(topN: 10);
        return {
          'ok': true,
          'kind': 'summary',
          'markdown': summary,
        };
      }
      final jsonStr = Sleuth.exportSnapshotJson();
      if (jsonStr == null || jsonStr.isEmpty) {
        return {
          'ok': false,
          'error': 'exportSnapshotJson returned null — is Sleuth.track active?',
        };
      }
      final decoded = jsonDecode(jsonStr);
      return {
        'ok': true,
        'kind': 'snapshot',
        'snapshot': decoded,
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Map<String, dynamic> summary({int topN = 5}) {
    if (kReleaseMode) {
      return {'ok': false, 'error': 'sleuth disabled in release'};
    }
    try {
      final md = Sleuth.exportSummary(topN: topN);
      return {
        'ok': md != null,
        'markdown': md,
        if (md == null) 'error': 'exportSummary null',
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Map<String, dynamic> diagnose() {
    if (kReleaseMode) {
      return {'ok': false, 'error': 'sleuth disabled in release'};
    }
    try {
      final d = Sleuth.diagnoseCaptureState();
      return {
        'ok': true,
        'initialized': d.initialized,
        'captureMode': d.captureMode,
        'vmConnected': d.vmConnected,
        'advisory': d.vmConnected
            ? null
            : 'Sleuth VM link down — GC/heap/shader/heavy_compute detectors '
                'may be silent. Relaunch with: flutter run --profile --no-dds',
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Flatten current issues from the live snapshot for MCP / reports.
  static Map<String, dynamic> issues({int limit = 50}) {
    if (kReleaseMode) {
      return {'ok': false, 'error': 'sleuth disabled in release'};
    }
    try {
      final snap = Sleuth.exportSnapshot();
      if (snap == null) {
        return {'ok': false, 'error': 'no snapshot'};
      }
      final list = <Map<String, dynamic>>[];
      try {
        final dynamic d = snap;
        final raw = d.currentIssues as List? ?? d.issues as List?;
        if (raw != null) {
          for (final item in raw.take(limit)) {
            if (item is Map) {
              list.add(Map<String, dynamic>.from(item));
            } else {
              list.add(_issueToMap(item));
            }
          }
        }
      } catch (_) {
        // Fall back to JSON round-trip.
        final jsonStr = Sleuth.exportSnapshotJson();
        if (jsonStr != null) {
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map) {
            final raw = decoded['currentIssues'] ?? decoded['issues'];
            if (raw is List) {
              for (final item in raw.take(limit)) {
                if (item is Map) {
                  list.add(Map<String, dynamic>.from(item));
                } else {
                  list.add({'raw': item.toString()});
                }
              }
            }
          }
        }
      }
      return {
        'ok': true,
        'count': list.length,
        'issues': list,
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Map<String, dynamic> routeHealth({String? routeName}) {
    if (kReleaseMode) {
      return {'ok': false, 'error': 'sleuth disabled in release'};
    }
    try {
      if (routeName != null && routeName.isNotEmpty) {
        return {
          'ok': true,
          'routeName': routeName,
          'healthScore': Sleuth.routeHealthScore(routeName),
        };
      }
      final history = Sleuth.routeHistory;
      if (history == null) {
        return {'ok': false, 'error': 'no route history'};
      }
      return {
        'ok': true,
        'routes': history.map((s) {
          return {
            'routeName': s.routeName,
            'healthScore': s.healthScore,
            'scaffoldHashKey': s.scaffoldHashKey,
            'tabVisitIndex': s.tabVisitIndex,
          };
        }).toList(),
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Map<String, dynamic> _issueToMap(Object item) {
    try {
      final dynamic d = item;
      return {
        'stableId': _try(() => d.stableId?.toString()),
        'id': _try(() => d.id?.toString()),
        'title': _try(() => d.title?.toString() ?? d.message?.toString()),
        'severity': _try(() => d.severity?.toString()),
        'category': _try(() => d.category?.toString()),
        'confidenceHint': _try(() => d.fixHint?.toString()),
        'detail': _try(() => d.detail?.toString()),
        'confidence': item.toString(),
      };
    } catch (_) {
      return {'raw': item.toString()};
    }
  }

  static Object? _try(Object? Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }
}
