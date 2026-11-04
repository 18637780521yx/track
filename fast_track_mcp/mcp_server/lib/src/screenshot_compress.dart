import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Timeline cover thumbs: resize + JPEG (MCP / host tools only — not App SDK).
///
/// Kept out of `fast_track_mcp_protocol` so host apps that pin an older
/// `archive` (e.g. 4.3.0) are not forced onto `image` → newer `archive`.
class ScreenshotCompress {
  ScreenshotCompress._();

  static const defaultMaxWidth = 360;
  static const defaultQuality = 70;

  /// Decode PNG/JPEG [bytes], downscale to [maxWidth], re-encode as JPEG.
  static ({Uint8List bytes, String dataUri, String ext}) compress(
    Uint8List bytes, {
    int maxWidth = defaultMaxWidth,
    int quality = defaultQuality,
  }) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        final b64 = base64Encode(bytes);
        return (
          bytes: bytes,
          dataUri: 'data:image/png;base64,$b64',
          ext: 'png',
        );
      }
      var out = decoded;
      if (out.width > maxWidth) {
        out = img.copyResize(
          out,
          width: maxWidth,
          interpolation: img.Interpolation.average,
        );
      }
      final jpg = Uint8List.fromList(
        img.encodeJpg(out, quality: quality.clamp(40, 95)),
      );
      return (
        bytes: jpg,
        dataUri: 'data:image/jpeg;base64,${base64Encode(jpg)}',
        ext: 'jpg',
      );
    } catch (_) {
      final b64 = base64Encode(bytes);
      return (
        bytes: bytes,
        dataUri: 'data:image/png;base64,$b64',
        ext: 'png',
      );
    }
  }

  static ({Uint8List bytes, String dataUri, String ext}) compressBase64(
    String base64, {
    int maxWidth = defaultMaxWidth,
    int quality = defaultQuality,
  }) {
    return compress(
      base64Decode(base64),
      maxWidth: maxWidth,
      quality: quality,
    );
  }
}
