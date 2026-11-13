import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Resolved interactive target under a screen position (manual recording).
class HitTarget {
  const HitTarget({
    required this.x,
    required this.y,
    this.key,
    this.text,
    this.label,
    this.hint,
    this.widgetType,
    this.role,
  });

  final double x;
  final double y;
  final String? key;
  final String? text;
  final String? label;
  final String? hint;
  final String? widgetType;
  final String? role;

  /// Short human label for reports / action name.
  ///
  /// Skips icon-font / Private Use Area glyphs (they show as □ in HTML).
  String get displayLabel {
    if (_usable(key)) return key!.trim();
    if (_usable(text)) return text!.trim();
    if (_usable(label)) return label!.trim();
    if (_usable(hint)) return hint!.trim();
    if (widgetType != null && widgetType!.isNotEmpty) {
      return '$widgetType@${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}';
    }
    return 'tap@${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}';
  }

  /// True when we already have a stable automation / human label.
  bool get hasStableLabel =>
      _usable(key) || _usable(text) || _usable(label) || _usable(hint);

  static bool _usable(String? s) {
    if (s == null) return false;
    final t = s.trim();
    if (t.isEmpty) return false;
    if (_isNoiseLabel(t)) return false;
    return t.runes.any((c) {
      if (c <= 0x1f || c == 0x7f) return false;
      if (c >= 0xe000 && c <= 0xf8ff) return false;
      if (c >= 0xf0000 && c <= 0xffffd) return false;
      if (c >= 0x100000 && c <= 0x10fffd) return false;
      return true;
    });
  }

  static bool _isNoiseLabel(String t) {
    final lower = t.toLowerCase();
    if (lower.contains('httpexception')) return true;
    if (lower.contains('socketexception')) return true;
    if (lower.contains('handshakeexception')) return true;
    if (lower.contains('clientexception')) return true;
    if (lower.contains('invalid statuscode')) return true;
    if (lower.contains('statuscode:')) return true;
    if (lower.contains('another exception was thrown')) return true;
    if (lower.contains('renderflex overflowed')) return true;
    if (lower.startsWith('exception:')) return true;
    if (lower.startsWith('error:')) return true;
    if (t.contains('uri = http')) return true;
    if (t.startsWith('http://') || t.startsWith('https://')) return true;
    if (t.length > 64 &&
        (lower.contains('https://') || lower.contains('http://'))) {
      return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        if (key != null) 'key': key,
        if (text != null) 'text': text,
        if (label != null) 'label': label,
        if (hint != null) 'hint': hint,
        if (widgetType != null) 'widgetType': widgetType,
        if (role != null) 'role': role,
        'displayLabel': displayLabel,
      };
}

/// Hit-test [position] and extract key / text / hint like flutter_skill.
class HitTargetResolver {
  /// Max elements visited while collecting nearby label text.
  static const int _maxTextVisits = 64;

  /// Max ancestor hops when looking for a row title outside the control.
  static const int _maxAncestorHops = 8;

  /// Hard cap for RenderObject→Element tree walk (profile / no DebugCreator).
  /// Keeps PointerUp bounded so IndexedStack pages cannot Input-ANR.
  static const int maxLookupVisits = 1800;

  static HitTarget resolve(
    Offset position, {
    int viewId = 0,
    int lookupVisitBudget = maxLookupVisits,
  }) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, viewId);

    final renderObjects = <RenderObject>[];
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderObject) renderObjects.add(target);
    }

    final lookup = _RenderObjectElementLookup(
      needed: renderObjects.toSet(),
      maxVisits: lookupVisitBudget,
    );
    final candidates = <Element>[];
    for (final ro in renderObjects) {
      final el = lookup.elementFor(ro);
      if (el != null) candidates.add(el);
    }

    final best = _pickBest(candidates);
    if (best == null) {
      return HitTarget(x: position.dx, y: position.dy);
    }
    return _fromElement(best, position);
  }

  static Element? _pickBest(List<Element> candidates) {
    if (candidates.isEmpty) return null;

    Element? scored;
    var bestScore = -1;
    for (final el in candidates) {
      final s = _score(el.widget);
      if (s > bestScore) {
        bestScore = s;
        scored = el;
      }
    }
    return scored ?? candidates.first;
  }

  static int _score(Widget w) {
    if (w is ListTile || w is RadioListTile || w is CheckboxListTile) return 100;
    if (w is ElevatedButton ||
        w is TextButton ||
        w is OutlinedButton ||
        w is FilledButton) {
      return 90;
    }
    if (w is IconButton || w is FloatingActionButton) return 85;
    if (w is InkWell || w is GestureDetector) return 80;
    if (w is TextField || w is TextFormField) return 75;
    if (w is Checkbox || w is Switch || w is Radio) return 70;
    // Forui / custom controls often only expose a Key + child Text.
    if (w.key is ValueKey<String> || w.key is ValueKey<int>) return 55;
    final type = w.runtimeType.toString();
    if (type.contains('Button') ||
        type.contains('Tile') ||
        type.contains('InkWell')) {
      return 50;
    }
    if (w is Text && HitTarget._usable(w.data)) return 30;
    if (w is RichText) return 20;
    if (type.contains('Listener')) return 5;
    return 10;
  }

  static HitTarget _fromElement(Element element, Offset position) {
    String? key;
    String? text;
    String? label;
    String? hint;
    String? role;
    var widgetType = element.widget.runtimeType.toString();

    void absorb(Element el, {required bool extractSubtreeText}) {
      final w = el.widget;
      if (key == null && w.key is ValueKey<String>) {
        key = (w.key as ValueKey<String>).value;
      } else if (key == null && w.key is ValueKey<int>) {
        key = (w.key as ValueKey<int>).value.toString();
      }

      if (w is TextField) {
        role ??= 'input';
        label ??= w.decoration?.labelText;
        hint ??= w.decoration?.hintText;
      } else if (w is TextFormField) {
        role ??= 'input';
      } else if (w is ListTile ||
          w is RadioListTile ||
          w is CheckboxListTile ||
          w is ElevatedButton ||
          w is TextButton ||
          w is OutlinedButton ||
          w is FilledButton ||
          w is IconButton ||
          w is FloatingActionButton ||
          w is InkWell ||
          w is GestureDetector ||
          _score(w) >= 50) {
        role ??= 'button';
        if (_score(w) >= 50) {
          widgetType = w.runtimeType.toString();
        }
        if (w is IconButton) {
          if (HitTarget._usable(w.tooltip)) text ??= w.tooltip;
        }
        if (w is FloatingActionButton) {
          if (HitTarget._usable(w.tooltip)) text ??= w.tooltip;
        }
        if (extractSubtreeText) {
          final t = _extractUsableText(el);
          if (t != null) text ??= t;
        }
      } else if (w is Semantics) {
        final s = w.properties.label ?? w.properties.tooltip;
        if (HitTarget._usable(s)) label ??= s;
      } else if (w is Text && HitTarget._usable(w.data)) {
        text ??= w.data!.trim();
      }
    }

    absorb(element, extractSubtreeText: true);

    var hops = 0;
    element.visitAncestorElements((ancestor) {
      hops += 1;
      if (hops > _maxAncestorHops) return false;
      final needText = !HitTarget._usable(key) &&
          !HitTarget._usable(text) &&
          !HitTarget._usable(label) &&
          !HitTarget._usable(hint);
      absorb(ancestor, extractSubtreeText: needText);
      return needText;
    });

    if (!HitTarget._usable(text) &&
        !HitTarget._usable(label) &&
        !HitTarget._usable(key)) {
      hops = 0;
      element.visitAncestorElements((ancestor) {
        hops += 1;
        if (hops > _maxAncestorHops) return false;
        final t = _extractUsableText(ancestor);
        if (t != null) {
          text = t;
          role ??= 'button';
          return false;
        }
        return true;
      });
    }

    return HitTarget(
      x: position.dx,
      y: position.dy,
      key: key,
      text: text,
      label: label,
      hint: hint,
      widgetType: widgetType,
      role: role,
    );
  }

  static String? _extractUsableText(Element element) {
    final found = <String>[];
    var visits = 0;
    void visit(Element e) {
      if (visits >= _maxTextVisits || found.length >= 8) return;
      visits += 1;
      final w = e.widget;
      if (w is ErrorWidget) return;
      if (w.runtimeType.toString().contains('ErrorWidget')) return;

      if (w is Text && HitTarget._usable(w.data)) {
        found.add(w.data!.trim());
      } else if (w is RichText) {
        final t = w.text.toPlainText().trim();
        if (HitTarget._usable(t)) found.add(t);
      }
      e.visitChildren(visit);
    }

    visit(element);
    if (found.isEmpty) return null;
    found.sort((a, b) {
      final byLen = a.length.compareTo(b.length);
      if (byLen != 0) return byLen;
      return a.compareTo(b);
    });
    return found.first;
  }
}

/// Hit-path-only RenderObject → Element map with early exit + visit budget.
class _RenderObjectElementLookup {
  _RenderObjectElementLookup({
    required Set<RenderObject> needed,
    required this.maxVisits,
  }) : _needed = {...needed};

  final Set<RenderObject> _needed;
  final int maxVisits;
  Map<RenderObject, Element>? _map;

  Element? elementFor(RenderObject renderObject) {
    final creator = renderObject.debugCreator;
    if (creator is DebugCreator) return creator.element;
    _map ??= _buildMap();
    return _map![renderObject];
  }

  Map<RenderObject, Element> _buildMap() {
    final map = <RenderObject, Element>{};
    if (_needed.isEmpty) return map;
    // ignore: invalid_use_of_protected_member
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return map;

    final pending = {..._needed};
    var visits = 0;
    void visit(Element el) {
      if (pending.isEmpty || visits >= maxVisits) return;
      visits += 1;
      if (el is RenderObjectElement) {
        final ro = el.renderObject;
        if (pending.remove(ro)) {
          map[ro] = el;
        }
      }
      el.visitChildren(visit);
    }

    visit(root);
    return map;
  }
}
