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

  static bool _usable(String? s) {
    if (s == null) return false;
    final t = s.trim();
    if (t.isEmpty) return false;
    // Prefer labels that contain at least one non-control, non-PUA char.
    return t.runes.any((c) {
      if (c <= 0x1f || c == 0x7f) return false;
      if (c >= 0xe000 && c <= 0xf8ff) return false;
      if (c >= 0xf0000 && c <= 0xffffd) return false;
      if (c >= 0x100000 && c <= 0x10fffd) return false;
      return true;
    });
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
  static HitTarget resolve(Offset position, {int viewId = 0}) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, viewId);

    final candidates = <Element>[];
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderObject) continue;
      final el = _elementFor(target);
      if (el != null) candidates.add(el);
    }

    final best = _pickBest(candidates);
    if (best == null) {
      return HitTarget(x: position.dx, y: position.dy);
    }

    return _fromElement(best, position);
  }

  /// Prefer real controls (ListTile / InkWell / buttons) over raw Listener/Text.
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
    if (w.key is ValueKey<String>) return 40;
    if (w is Text && HitTarget._usable(w.data)) return 30;
    if (w is RichText) return 20;
    // Raw Listener / RenderPointerListener — last resort.
    if (w.runtimeType.toString().contains('Listener')) return 5;
    return 10;
  }

  static Element? _elementFor(RenderObject renderObject) {
    Element? found;
    void visit(Element el) {
      if (found != null) return;
      if (el.renderObject == renderObject) {
        found = el;
        return;
      }
      el.visitChildren(visit);
    }

    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    final root = binding.rootElement;
    if (root != null) visit(root);
    return found;
  }

  static HitTarget _fromElement(Element element, Offset position) {
    String? key;
    String? text;
    String? label;
    String? hint;
    String? role;
    var widgetType = element.widget.runtimeType.toString();

    void absorb(Element el) {
      final w = el.widget;
      if (key == null && w.key is ValueKey<String>) {
        key = (w.key as ValueKey<String>).value;
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
          w is GestureDetector) {
        role ??= 'button';
        // Prefer this control's type in the report.
        if (_score(w) >= 80) {
          widgetType = w.runtimeType.toString();
        }
        if (w is IconButton) {
          if (HitTarget._usable(w.tooltip)) text ??= w.tooltip;
        }
        if (w is FloatingActionButton) {
          if (HitTarget._usable(w.tooltip)) text ??= w.tooltip;
        }
        final t = _extractUsableText(el);
        if (t != null) text ??= t;
      } else if (w is Semantics) {
        final s = w.properties.label ?? w.properties.tooltip;
        if (HitTarget._usable(s)) label ??= s;
      } else if (w is Text && HitTarget._usable(w.data)) {
        text ??= w.data!.trim();
      }
    }

    absorb(element);

    // Climb ancestors: InkWell / ListTile often wrap the leaf Listener/Icon.
    element.visitAncestorElements((ancestor) {
      absorb(ancestor);
      // Keep walking until we have a usable label or leave the interactive row.
      final done = HitTarget._usable(key) ||
          HitTarget._usable(text) ||
          HitTarget._usable(label) ||
          HitTarget._usable(hint);
      return !done;
    });

    // Last pass: if still empty, search a wider ancestor subtree (row title).
    if (!HitTarget._usable(text) &&
        !HitTarget._usable(label) &&
        !HitTarget._usable(key)) {
      element.visitAncestorElements((ancestor) {
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

  /// First usable (non-icon-font) plain text under [element].
  static String? _extractUsableText(Element element) {
    String? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is Text && HitTarget._usable(w.data)) {
        found = w.data!.trim();
        return;
      }
      if (w is RichText) {
        final t = w.text.toPlainText().trim();
        if (HitTarget._usable(t)) {
          found = t;
          return;
        }
      }
      e.visitChildren(visit);
    }

    visit(element);
    return found;
  }
}
