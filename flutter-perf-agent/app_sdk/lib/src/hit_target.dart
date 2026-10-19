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
  String get displayLabel {
    if (key != null && key!.isNotEmpty) return key!;
    if (text != null && text!.trim().isNotEmpty) return text!.trim();
    if (label != null && label!.trim().isNotEmpty) return label!.trim();
    if (hint != null && hint!.trim().isNotEmpty) return hint!.trim();
    if (widgetType != null) return '$widgetType@${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}';
    return 'tap@${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}';
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

    Element? best;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderObject) continue;
      final el = _elementFor(target);
      if (el == null) continue;
      if (_isInteractive(el.widget) || _hasIdentity(el)) {
        best = el;
        break;
      }
      best ??= el;
    }

    if (best == null) {
      return HitTarget(x: position.dx, y: position.dy);
    }

    return _fromElement(best, position);
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

  static bool _isInteractive(Widget w) {
    return w is ElevatedButton ||
        w is TextButton ||
        w is OutlinedButton ||
        w is IconButton ||
        w is FloatingActionButton ||
        w is TextField ||
        w is TextFormField ||
        w is Checkbox ||
        w is Switch ||
        w is InkWell ||
        w is GestureDetector ||
        w is ListTile;
  }

  static bool _hasIdentity(Element el) {
    final w = el.widget;
    if (w.key is ValueKey<String>) return true;
    if (w is Text && (w.data?.isNotEmpty ?? false)) return true;
    return false;
  }

  static HitTarget _fromElement(Element element, Offset position) {
    String? key;
    String? text;
    String? label;
    String? hint;
    String? role;
    final widget = element.widget;
    final widgetType = widget.runtimeType.toString();

    if (widget.key is ValueKey<String>) {
      key = (widget.key as ValueKey<String>).value;
    }

    if (widget is TextField) {
      role = 'input';
      label = widget.decoration?.labelText;
      hint = widget.decoration?.hintText;
    } else if (widget is TextFormField) {
      role = 'input';
      void findField(Element e) {
        final w = e.widget;
        if (w is TextField) {
          label = w.decoration?.labelText;
          hint = w.decoration?.hintText;
          return;
        }
        e.visitChildren(findField);
      }

      findField(element);
    } else if (widget is ElevatedButton ||
        widget is TextButton ||
        widget is OutlinedButton ||
        widget is IconButton ||
        widget is FloatingActionButton ||
        widget is InkWell ||
        widget is GestureDetector ||
        widget is ListTile) {
      role = 'button';
      text = _extractText(element);
      if (widget is IconButton) {
        text ??= widget.tooltip;
      }
      if (widget is FloatingActionButton) {
        text ??= widget.tooltip;
      }
    } else if (widget is Text) {
      text = widget.data;
    }

    // Walk parents for ValueKey / label if leaf has none.
    if (key == null || (text == null && label == null && hint == null)) {
      element.visitAncestorElements((ancestor) {
        final w = ancestor.widget;
        if (key == null && w.key is ValueKey<String>) {
          key = (w.key as ValueKey<String>).value;
        }
        if (label == null && w is TextField) {
          label = w.decoration?.labelText;
          hint ??= w.decoration?.hintText;
          role ??= 'input';
        }
        if (text == null) {
          final t = _extractText(ancestor);
          if (t != null && t.isNotEmpty) text = t;
        }
        return key == null || (text == null && label == null);
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

  static String? _extractText(Element element) {
    String? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is Text && w.data != null && w.data!.trim().isNotEmpty) {
        found = w.data!.trim();
        return;
      }
      if (w is RichText) {
        final t = w.text.toPlainText().trim();
        if (t.isNotEmpty) {
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
