import 'flutter_skill_client.dart';
import 'flutter_skill_vm_client.dart';

/// Distinguishes "in widget tree" from "on screen now", and taps with
/// **minimal RPCs**.
///
/// Fast path: fresh interactive cache → skip re-inspect.
/// Otherwise: one inspect → direct tap | scrollTo+tap | limited swipe.
///
/// App-agnostic: no hardcoded tab/chrome label lists.
class VisibilityAssist {
  VisibilityAssist._();

  static Map<String, dynamic>? _cachedEnriched;
  static DateTime? _cacheAt;
  static const _cacheTtl = Duration(milliseconds: 1500);

  static void clearCache() {
    _cachedEnriched = null;
    _cacheAt = null;
  }

  /// Populate cache from an already-fetched snapshot (e.g. get_ui_snapshot).
  static void warmCache(Map<String, dynamic> enriched) {
    _cachedEnriched = enriched;
    _cacheAt = DateTime.now();
  }

  /// Annotate interactive elements with viewport hints.
  static Map<String, dynamic> enrichInteractive(Map<String, dynamic> raw) {
    final elements = _asMaps(raw['elements'] ?? raw['data']);
    final viewportH = estimateViewportHeight(elements);
    final annotated = <Map<String, dynamic>>[];
    final offScreen = <String>[];
    final inView = <String>[];

    for (final e in elements) {
      final bounds = parseBounds(e['bounds'] ?? e['rect']);
      final text = '${e['text'] ?? ''}'.trim();
      final visibility = classify(
        bounds: bounds,
        viewportHeight: viewportH,
        hittable: e['hittable'] == true,
        visible: e['visible'] != false,
      );
      final copy = Map<String, dynamic>.from(e);
      copy['inViewport'] = visibility.inViewport;
      copy['needsScroll'] = visibility.needsScroll;
      copy['visibility'] = visibility.label;
      annotated.add(copy);
      if (text.isNotEmpty) {
        if (visibility.needsScroll) {
          offScreen.add(text);
        } else if (visibility.inViewport) {
          inView.add(text);
        }
      }
    }

    return {
      ...raw,
      'elements': annotated,
      'viewport': {
        'estimatedHeight': viewportH,
        'note':
            'estimatedHeight from hittable geometry (app-agnostic); '
            'needsScroll ≈ below fold. hittable=false alone ≠ feature-off.',
      },
      'offScreenTexts': offScreen.toSet().toList(),
      'inViewportTexts': inView.toSet().toList(),
    };
  }

  /// Precise tap with as few round-trips as possible.
  static Future<Map<String, dynamic>> tapEnsuringVisible(
    FlutterSkillClient client, {
    required String target,
    int maxSwipeRetries = 2,
    double swipeDistance = 360,
  }) async {
    final t = target.trim();
    final meta = <String, dynamic>{
      'scrollIntoView': true,
      'target': t,
    };

    // Resolve match via cache or one interactive (no app-specific shortcuts).
    final enriched = await _interactiveCached(client, meta);
    if (enriched == null) {
      final tap = await client.tap(text: t, key: t);
      return {...tap, ...meta, 'path': 'inspect_fail_direct_tap'};
    }

    final match = pickBestMatch(_asMaps(enriched['elements']), t);
    meta['match'] = match == null
        ? null
        : {
            'text': match['text'],
            'hittable': match['hittable'] == true,
            'inViewport': match['inViewport'] == true,
            'needsScroll': match['needsScroll'] == true,
            'visibility': match['visibility'],
          };

    if (match == null) {
      return {
        'success': false,
        'error': 'No element matching "$t" in interactive tree',
        ...meta,
        'path': 'not_found',
        'uiHint': {
          'offScreenTexts': enriched['offScreenTexts'],
          'inViewportTexts': enriched['inViewportTexts'],
        },
      };
    }

    final inViewport = match['inViewport'] == true;
    final hittable = match['hittable'] == true;
    final needsScroll = match['needsScroll'] == true;

    // --- 2) On screen + tappable → tap only ---
    if (inViewport && hittable) {
      final tap = await client.tap(text: t, key: t);
      // Invalidate cache after gesture (layout may change).
      clearCache();
      return {
        ...tap,
        ...meta,
        'path': 'direct_tap',
        'rpc': meta['inspectCached'] == true
            ? ['tap']
            : ['interactive', 'tap'],
      };
    }

    // --- 3) Off-screen → one scrollTo + tap ---
    if (needsScroll || !hittable) {
      Map<String, dynamic>? scroll;
      try {
        scroll = await client.scrollTo(text: t);
        if (!FlutterSkillVmClient.isOk(scroll)) {
          scroll = await client.scrollTo(key: t);
        }
      } catch (e) {
        scroll = {'success': false, 'error': e.toString()};
      }
      meta['scrollTo'] = scroll;
      clearCache();

      final tap = await client.tap(text: t, key: t);
      if (FlutterSkillVmClient.isOk(tap)) {
        return {
          ...tap,
          ...meta,
          'path': 'scroll_then_tap',
          'rpc': [
            if (meta['inspectCached'] != true) 'interactive',
            'scrollTo',
            'tap',
          ],
        };
      }

      for (var i = 0; i < maxSwipeRetries; i++) {
        try {
          await client.swipe(direction: 'up', distance: swipeDistance);
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final again = await client.tap(text: t, key: t);
        if (FlutterSkillVmClient.isOk(again)) {
          clearCache();
          return {
            ...again,
            ...meta,
            'path': 'swipe_retry_tap',
            'swipesBeforeHit': i + 1,
          };
        }
      }

      return {
        'success': false,
        'error': 'tap failed after targeted scroll',
        ...meta,
        'path': 'failed_after_scroll',
        'lastResult': tap,
        'uiHint': {
          'offScreenTexts': enriched['offScreenTexts'],
          'inViewportTexts': enriched['inViewportTexts'],
          'viewport': enriched['viewport'],
        },
      };
    }

    final tap = await client.tap(text: t, key: t);
    clearCache();
    return {
      ...tap,
      ...meta,
      'path': 'obscured_direct_tap',
    };
  }

  static Future<Map<String, dynamic>?> _interactiveCached(
    FlutterSkillClient client,
    Map<String, dynamic> meta,
  ) async {
    final now = DateTime.now();
    final cached = _cachedEnriched;
    final at = _cacheAt;
    if (cached != null &&
        at != null &&
        now.difference(at) <= _cacheTtl) {
      meta['inspectCached'] = true;
      meta['inspect'] = 'cache';
      return cached;
    }
    try {
      final enriched = enrichInteractive(await client.interactive());
      _cachedEnriched = enriched;
      _cacheAt = now;
      meta['inspectCached'] = false;
      meta['inspect'] = 'ok';
      return enriched;
    } catch (e) {
      meta['inspect'] = 'fail:$e';
      return null;
    }
  }

  /// Prefer exact text; score hittable+inViewport highest.
  static Map<String, dynamic>? pickBestMatch(
    List<Map<String, dynamic>> elements,
    String target,
  ) {
    final t = target.trim();
    if (t.isEmpty) return null;

    Map<String, dynamic>? best;
    var bestScore = -1;

    for (final e in elements) {
      final text = '${e['text'] ?? ''}'.trim();
      final key = '${e['key'] ?? e['ref'] ?? ''}'.trim();
      final exactText = text == t;
      final exactKey = key == t || key.endsWith('.$t') || key.contains(t);
      if (!exactText && !exactKey) continue;

      var score = 0;
      if (exactText) score += 8;
      if (exactKey) score += 4;
      if (e['hittable'] == true) score += 4;
      if (e['inViewport'] == true) score += 2;
      if (e['needsScroll'] == true) score += 1;
      if (e['visible'] != false) score += 1;

      if (score > bestScore) {
        bestScore = score;
        best = e;
      }
    }
    return best;
  }

  static VisibilityHit classify({
    required ({double x, double y, double w, double h})? bounds,
    required double viewportHeight,
    required bool hittable,
    required bool visible,
  }) {
    if (bounds == null) {
      return VisibilityHit(
        inViewport: hittable && visible,
        needsScroll: !hittable && visible,
        label: hittable ? 'unknown_hittable' : 'unknown_maybe_off_screen',
      );
    }
    final top = bounds.y;
    final bottom = bounds.y + bounds.h;
    final centerY = top + bounds.h / 2;
    final viewBottom = viewportHeight;

    final fullyAbove = bottom <= 0;
    final fullyBelow = top >= viewBottom;
    final centerInView = centerY > 0 && centerY < viewBottom;

    if (fullyBelow) {
      return const VisibilityHit(
        inViewport: false,
        needsScroll: true,
        label: 'off_screen',
      );
    }
    if (fullyAbove) {
      return const VisibilityHit(
        inViewport: false,
        needsScroll: true,
        label: 'off_screen_above',
      );
    }
    if (centerInView && hittable) {
      return const VisibilityHit(
        inViewport: true,
        needsScroll: false,
        label: 'in_viewport',
      );
    }
    if (centerInView && visible) {
      return const VisibilityHit(
        inViewport: true,
        needsScroll: false,
        label: 'obscured_or_offstage',
      );
    }
    if (top < viewBottom && bottom > viewBottom && !hittable) {
      return const VisibilityHit(
        inViewport: false,
        needsScroll: true,
        label: 'off_screen',
      );
    }
    return VisibilityHit(
      inViewport: centerInView,
      needsScroll: !centerInView,
      label: centerInView ? 'in_viewport' : 'off_screen',
    );
  }

  /// Viewport height from geometry only (works across apps).
  ///
  /// Prefer the highest bottom among *hittable* widgets whose top is still in
  /// a plausible first-screen band — usually bottom nav / FABs / app bars.
  /// Scrollable off-screen content tends to have much larger [y] and is ignored.
  static double estimateViewportHeight(List<Map<String, dynamic>> elements) {
    var chromeBottom = 0.0;
    final bottoms = <double>[];

    for (final e in elements) {
      final b = parseBounds(e['bounds'] ?? e['rect']);
      if (b == null) continue;
      if (b.y < 0 || b.y >= 1000) continue;
      final bottom = b.y + b.h;
      if (bottom <= 0 || bottom > 1200) continue;
      if (e['hittable'] == true) {
        bottoms.add(bottom);
        if (bottom > chromeBottom) chromeBottom = bottom;
      }
    }

    if (chromeBottom >= 500) return chromeBottom;

    // Fallback: 90th-percentile of all in-band bottoms (if few hittable).
    if (bottoms.length >= 3) {
      bottoms.sort();
      return bottoms[(bottoms.length * 0.9).floor().clamp(0, bottoms.length - 1)];
    }
    return 844;
  }

  static ({double x, double y, double w, double h})? parseBounds(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    double? n(Object? v) => v is num ? v.toDouble() : null;
    final x = n(m['x']) ?? n(m['left']);
    final y = n(m['y']) ?? n(m['top']);
    final w = n(m['w']) ?? n(m['width']);
    final h = n(m['h']) ?? n(m['height']);
    if (x == null || y == null || w == null || h == null) return null;
    return (x: x, y: y, w: w, h: h);
  }

  static List<Map<String, dynamic>> _asMaps(Object? raw) {
    if (raw is Map && raw['elements'] is List) {
      return _asMaps(raw['elements']);
    }
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }
}

class VisibilityHit {
  const VisibilityHit({
    required this.inViewport,
    required this.needsScroll,
    required this.label,
  });

  final bool inViewport;
  final bool needsScroll;
  final String label;
}
