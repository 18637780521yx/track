import 'dart:io';

import 'package:flutter_perf_agent/src/reports_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('resolveSync keeps desktop relative path', () {
    if (Platform.isIOS || Platform.isAndroid) return;
    expect(ReportsPath.resolveSync('reports'), 'reports');
  });

  test('resolveSync remaps host paths on mobile-shaped input via ensureWritable',
      () async {
    final dir = await ReportsPath.ensureWritable('reports');
    expect(Directory(dir).existsSync(), isTrue);
    // Probe file should be gone after ensureWritable.
    expect(File(p.join(dir, '.perf_agent_write_probe')).existsSync(), isFalse);
  });

  test('resolveSync remaps /Users host path', () {
    if (!(Platform.isIOS || Platform.isAndroid)) {
      // On desktop, absolute /Users is left as-is (may be valid).
      final r = ReportsPath.resolveSync('/Users/fc/Desktop/reports');
      expect(r, '/Users/fc/Desktop/reports');
      return;
    }
    final r = ReportsPath.resolveSync('/Users/fc/Desktop/reports');
    expect(r.contains('flutter_perf_agent'), isTrue);
  });
}
