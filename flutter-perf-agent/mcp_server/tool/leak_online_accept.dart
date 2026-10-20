/// Offline accept for 0.8.7 online sampling (sampleRate 0 / 1 + event shape).
///
/// Run from repo:
///   cd flutter-perf-agent/app_sdk && flutter test test/leak_online_test.dart
///
/// Optional device accept (release lite):
///   cd example_app && flutter run --release --dart-define=LEAK_ONLINE=true
///   → open profile push page, pop; logcat `[LeakOnlineEvent]` with transition_leak.
///
/// Debug MCP path must still pass:
///   dart run tool/leak_multi_round_accept.dart  (from mcp_server, app running)
library;

import 'dart:io';

Future<void> main() async {
  final sdkDir = Directory(
    '${File(Platform.script.toFilePath()).parent.parent.parent.path}/app_sdk',
  );
  stdout.writeln('Running flutter test in ${sdkDir.path} ...');
  final r = await Process.run(
    'flutter',
    ['test', 'test/leak_online_test.dart'],
    workingDirectory: sdkDir.path,
    runInShell: true,
  );
  stdout.write(r.stdout);
  stderr.write(r.stderr);
  if (r.exitCode != 0) {
    stderr.writeln('FAIL: leak_online unit accept');
    exit(r.exitCode);
  }
  stdout.writeln('PASS: leak_online sampleRate 0/1 + event sink');
  stdout.writeln(
    'Manual (optional): flutter run --release --dart-define=LEAK_ONLINE=true',
  );
}
