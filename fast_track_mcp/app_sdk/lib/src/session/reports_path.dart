import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Resolve a writable reports directory for the current platform.
///
/// On iOS/Android the process cwd is not writable, so a relative `reports`
/// (or a Mac/Windows path pushed by MCP) must be remapped into the sandbox.
class ReportsPath {
  ReportsPath._();

  static String? _mobileCached;

  /// Sync remap for session start / init assignment.
  static String resolveSync(String configured) {
    final raw = configured.trim();
    if (raw.isEmpty) return _platformDefault();
    if (kIsWeb) return raw;

    if (Platform.isIOS || Platform.isAndroid) {
      if (_isHostMachinePath(raw) || !p.isAbsolute(raw)) {
        return _mobileDefault();
      }
      return raw;
    }
    return raw;
  }

  /// Ensure [configured] (after [resolveSync]) exists and is writable.
  static Future<String> ensureWritable(String configured) async {
    final resolved = resolveSync(configured);
    try {
      final dir = Directory(resolved);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      // Prove write access (create may succeed on some RO mounts).
      final probe = File(p.join(dir.path, '.perf_agent_write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return dir.path;
    } catch (e) {
      final fallback = _mobileDefault();
      final dir = Directory(fallback);
      await dir.create(recursive: true);
      debugPrint(
        '[ReportsPath] "$resolved" not writable ($e); fallback → $fallback',
      );
      return fallback;
    }
  }

  static String _platformDefault() {
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      return _mobileDefault();
    }
    return 'reports';
  }

  static String _mobileDefault() {
    return _mobileCached ??=
        p.join(Directory.systemTemp.path, 'fast_track_mcp', 'reports');
  }

  /// Paths that only make sense on the MCP host, not inside a phone sandbox.
  static bool _isHostMachinePath(String path) {
    if (path.startsWith('/Users/')) return true;
    if (path.startsWith('/home/')) return true;
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) return true;
    if (path.contains('/Desktop/') || path.contains('\\Desktop\\')) {
      return true;
    }
    return false;
  }
}
