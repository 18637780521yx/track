import 'dart:convert';
import 'dart:io';

/// Fill `screenshotDataUri` from on-disk `screenshotPath` when missing
/// (JSON on disk strips data-URIs; HTML rebuild / live reports need covers).
Future<void> hydrateReportScreenshots(Map<String, dynamic> report) async {
  final steps = report['steps'];
  if (steps is! List) return;
  for (final s in steps) {
    if (s is! Map) continue;
    await _hydrateShotFields(s);
    final events = s['events'];
    if (events is! List) continue;
    for (final e in events) {
      if (e is! Map) continue;
      await _hydrateShotFields(e);
    }
  }
}

Future<void> _hydrateShotFields(Map shot) async {
  if (shot['screenshotDataUri'] != null) return;
  final path = shot['screenshotPath']?.toString();
  if (path == null || path.isEmpty) return;
  final f = File(path);
  if (!await f.exists()) return;
  try {
    final bytes = await f.readAsBytes();
    final lower = path.toLowerCase();
    final mime = (lower.endsWith('.jpg') || lower.endsWith('.jpeg'))
        ? 'image/jpeg'
        : 'image/png';
    shot['screenshotDataUri'] = 'data:$mime;base64,${base64Encode(bytes)}';
  } catch (_) {}
}
