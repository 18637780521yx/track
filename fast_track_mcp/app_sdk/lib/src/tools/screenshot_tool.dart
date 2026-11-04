import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// Result of a PNG screenshot capture.
class ScreenshotShot {
  const ScreenshotShot({this.path, this.dataUri, this.bytes});

  final String? path;
  final String? dataUri;
  final Uint8List? bytes;

  bool get isEmpty => path == null && dataUri == null && bytes == null;
}

/// Standalone Flutter scene screenshot utility.
///
/// Captures the root [OffsetLayer] (fallback: [RenderRepaintBoundary]) as PNG.
/// Callable from Bridge / MCP / tests.
class ScreenshotTool {
  ScreenshotTool._();

  /// Default cover width for HTML thumbs (keeps files small without JPEG).
  static const double defaultMaxWidth = 360;

  /// Rasterize the current Flutter scene to a [ui.Image].
  ///
  /// Caller must [ui.Image.dispose] the result.
  static Future<ui.Image?> captureScene({
    double maxWidth = defaultMaxWidth,
    double fallbackPixelRatio = 0.35,
  }) async {
    final binding = WidgetsBinding.instance;
    // ignore: invalid_use_of_protected_member
    final renderObject = binding.rootElement?.renderObject;
    if (renderObject == null) return null;

    RenderObject root = renderObject;
    while (root.parent != null) {
      root = root.parent!;
    }
    // ignore: invalid_use_of_protected_member
    final layer = root.layer;
    if (layer is OffsetLayer) {
      final view = binding.platformDispatcher.views.first;
      final logicalW = view.physicalSize.width / view.devicePixelRatio;
      final scale = (logicalW <= 0)
          ? 1.0
          : (maxWidth / logicalW).clamp(0.15, 1.0);
      return layer.toImage(
        Offset.zero & view.physicalSize,
        pixelRatio: scale / view.devicePixelRatio,
      );
    }
    if (renderObject is RenderRepaintBoundary) {
      return renderObject.toImage(pixelRatio: fallbackPixelRatio);
    }
    return null;
  }

  /// Capture PNG bytes only (no disk write).
  static Future<Uint8List?> capturePngBytes({
    double maxWidth = defaultMaxWidth,
    bool waitEndOfFrame = true,
  }) async {
    try {
      if (waitEndOfFrame) {
        await SchedulerBinding.instance.endOfFrame;
      }
      final image = await captureScene(maxWidth: maxWidth);
      if (image == null) return null;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return null;
      return data.buffer.asUint8List();
    } catch (e) {
      debugPrint('[ScreenshotTool] capturePngBytes failed: $e');
      return null;
    }
  }

  /// Capture PNG, optionally write under `[reportsDir]/screenshots/[sessionId]/`,
  /// and/or return a data-URI for inline HTML.
  static Future<ScreenshotShot> capture({
    String? fileName,
    String? reportsDir,
    String? sessionId,
    double maxWidth = defaultMaxWidth,
    bool includeDataUri = true,
    bool saveToDisk = true,
    bool waitEndOfFrame = true,
  }) async {
    try {
      final bytes = await capturePngBytes(
        maxWidth: maxWidth,
        waitEndOfFrame: waitEndOfFrame,
      );
      if (bytes == null || bytes.isEmpty) return const ScreenshotShot();

      String? path;
      if (saveToDisk && reportsDir != null && reportsDir.isNotEmpty) {
        final sid = (sessionId == null || sessionId.isEmpty) ? 'shot' : sessionId;
        final name = (fileName == null || fileName.isEmpty)
            ? '${DateTime.now().millisecondsSinceEpoch}.png'
            : (fileName.endsWith('.png') ? fileName : '$fileName.png');
        final dir = Directory(p.join(reportsDir, 'screenshots', sid));
        if (!await dir.exists()) await dir.create(recursive: true);
        path = p.join(dir.path, name);
        await File(path).writeAsBytes(bytes);
      }

      final dataUri = includeDataUri
          ? 'data:image/png;base64,${base64Encode(bytes)}'
          : null;

      return ScreenshotShot(path: path, dataUri: dataUri, bytes: bytes);
    } catch (e) {
      debugPrint('[ScreenshotTool] capture failed: $e');
      return const ScreenshotShot();
    }
  }
}
