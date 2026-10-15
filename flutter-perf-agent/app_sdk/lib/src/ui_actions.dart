import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Legacy semantics tap / UI dump.
///
/// **Primary UI driver is flutter_skill** (VM extensions). This class remains
/// as a Bridge `/tap` fallback and for `/ui` listing when flutter_skill is
/// unavailable.
class UiActions {
  static SemanticsOwner? get _semanticsOwner {
    final binding = WidgetsBinding.instance;
    binding.ensureSemantics();
    // ignore: deprecated_member_use
    return binding.pipelineOwner.semanticsOwner ??
        RendererBinding.instance.rootPipelineOwner.semanticsOwner;
  }

  /// Find a semantics node whose label/value/tooltip contains [desc], then tap.
  static Future<Map<String, dynamic>> tapByDescription(String desc) async {
    WidgetsBinding.instance.ensureSemantics();

    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 16));

    final owner = _semanticsOwner;
    if (owner == null) {
      return {
        'ok': false,
        'error': 'semanticsOwner is null — ensure Semantics is enabled',
      };
    }

    final root = owner.rootSemanticsNode;
    if (root == null) {
      return {'ok': false, 'error': 'rootSemanticsNode is null'};
    }

    final needle = desc.trim().toLowerCase();
    final matches = <SemanticsNode>[];
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      final hay = [
        data.label,
        data.value,
        data.tooltip,
        data.hint,
      ].where((s) => s.trim().isNotEmpty).join(' ').toLowerCase();
      if (hay.contains(needle)) {
        matches.add(node);
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(root);

    if (matches.isEmpty) {
      return {
        'ok': false,
        'error': 'No semantics node matching "$desc"',
        'hint':
            'Prefer flutter_skill tap (text/key). Or add Semantics(label: ...).',
      };
    }

    SemanticsNode target = matches.first;
    for (final m in matches) {
      final d = m.getSemanticsData();
      if (d.hasAction(ui.SemanticsAction.tap) || _isButton(d)) {
        target = m;
        break;
      }
    }

    final transform = target.transform;
    final rect = target.rect;
    Offset center = rect.center;
    if (transform != null) {
      center = MatrixUtils.transformPoint(transform, center);
    }

    SemanticsNode? parent = target.parent;
    while (parent != null) {
      final t = parent.transform;
      if (t != null) {
        center = MatrixUtils.transformPoint(t, center);
      }
      parent = parent.parent;
    }

    await _injectTap(center);

    return {
      'ok': true,
      'legacy': true,
      'targetDesc': desc,
      'x': center.dx,
      'y': center.dy,
      'label': target.getSemanticsData().label,
      'matchCount': matches.length,
    };
  }

  static bool _isButton(SemanticsData data) {
    try {
      return data.flagsCollection.isButton;
    } catch (_) {
      // ignore: deprecated_member_use
      return data.hasFlag(ui.SemanticsFlag.isButton);
    }
  }

  static bool _isTextField(SemanticsData data) {
    try {
      return data.flagsCollection.isTextField;
    } catch (_) {
      // ignore: deprecated_member_use
      return data.hasFlag(ui.SemanticsFlag.isTextField);
    }
  }

  static Future<void> _injectTap(Offset position) async {
    final binding = GestureBinding.instance;
    final pointer = _nextPointer++;
    final stamp = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);

    binding.handlePointerEvent(
      PointerAddedEvent(
        pointer: pointer,
        kind: PointerDeviceKind.touch,
        position: position,
        timeStamp: stamp,
      ),
    );
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        kind: PointerDeviceKind.touch,
        position: position,
        timeStamp: stamp,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        kind: PointerDeviceKind.touch,
        position: position,
        timeStamp: stamp + const Duration(milliseconds: 40),
      ),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(
        pointer: pointer,
        kind: PointerDeviceKind.touch,
        position: position,
        timeStamp: stamp + const Duration(milliseconds: 41),
      ),
    );
  }

  static int _nextPointer = 90001;

  static List<Map<String, dynamic>> dumpInteractive() {
    WidgetsBinding.instance.ensureSemantics();
    final owner = _semanticsOwner;
    final root = owner?.rootSemanticsNode;
    if (root == null) return const [];

    final out = <Map<String, dynamic>>[];
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      final label = data.label.trim();
      final actionable = data.hasAction(ui.SemanticsAction.tap) ||
          _isButton(data) ||
          _isTextField(data);
      if (label.isNotEmpty && actionable) {
        out.add({
          'label': label,
          'value': data.value,
          'isButton': _isButton(data),
          'isTextField': _isTextField(data),
          'rect': {
            'l': node.rect.left,
            't': node.rect.top,
            'r': node.rect.right,
            'b': node.rect.bottom,
          },
        });
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(root);
    return out;
  }
}
