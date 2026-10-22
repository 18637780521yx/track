import 'package:flutter_perf_agent_mcp/src/visibility_assist.dart';
import 'package:test/test.dart';

void main() {
  group('VisibilityAssist.classify', () {
    test('below fold → needsScroll', () {
      final hit = VisibilityAssist.classify(
        bounds: (x: 300, y: 920, w: 64, h: 48),
        viewportHeight: 850,
        hittable: false,
        visible: true,
      );
      expect(hit.needsScroll, isTrue);
      expect(hit.inViewport, isFalse);
      expect(hit.label, 'off_screen');
    });

    test('on screen hittable → in_viewport', () {
      final hit = VisibilityAssist.classify(
        bounds: (x: 20, y: 100, w: 80, h: 40),
        viewportHeight: 850,
        hittable: true,
        visible: true,
      );
      expect(hit.inViewport, isTrue);
      expect(hit.needsScroll, isFalse);
    });

    test('on screen but not hittable → obscured, not needsScroll', () {
      final hit = VisibilityAssist.classify(
        bounds: (x: 20, y: 200, w: 80, h: 40),
        viewportHeight: 850,
        hittable: false,
        visible: true,
      );
      expect(hit.inViewport, isTrue);
      expect(hit.needsScroll, isFalse);
      expect(hit.label, 'obscured_or_offstage');
    });
  });

  group('VisibilityAssist.pickBestMatch', () {
    test('prefers hittable + inViewport', () {
      final best = VisibilityAssist.pickBestMatch([
        {
          'text': '签到',
          'hittable': false,
          'inViewport': false,
          'needsScroll': true,
          'visible': true,
        },
        {
          'text': '签到',
          'hittable': true,
          'inViewport': true,
          'needsScroll': false,
          'visible': true,
        },
      ], '签到');
      expect(best?['hittable'], isTrue);
      expect(best?['inViewport'], isTrue);
    });
  });

  group('VisibilityAssist.enrichInteractive', () {
    test('annotates offScreenTexts from geometry (app-agnostic)', () {
      final enriched = VisibilityAssist.enrichInteractive({
        'elements': [
          {
            'text': 'TabA',
            'hittable': true,
            'visible': true,
            'bounds': {'x': 300, 'y': 780, 'w': 70, 'h': 50},
          },
          {
            'text': 'DeepAction',
            'hittable': false,
            'visible': true,
            'bounds': {'x': 300, 'y': 1100, 'width': 64, 'height': 48},
          },
        ],
      });
      expect(enriched['viewport']['estimatedHeight'], greaterThanOrEqualTo(800));
      expect(enriched['offScreenTexts'], contains('DeepAction'));
      expect(enriched['inViewportTexts'], contains('TabA'));
      final els = enriched['elements'] as List;
      final deep = els.cast<Map>().firstWhere((e) => e['text'] == 'DeepAction');
      expect(deep['needsScroll'], isTrue);
    });
  });
}
