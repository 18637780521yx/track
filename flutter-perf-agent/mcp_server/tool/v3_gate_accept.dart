/// Offline accept for 0.9.0 V3 gate / modal helpers.
///
///   cd flutter-perf-agent/app_sdk && flutter test test/
///
/// Manual modal (app running): 我的 → 打开泄漏 Dialog → 关闭 → 报告 leak。
/// Manual gate: set requireMultiRound true in perf_agent_config.json.
/// Manual VM: set leakVmDeepProbe true; probe JSON may include vmDeep.
library;

import 'dart:io';

Future<void> main() async {
  final sdkDir = Directory(
    '${File(Platform.script.toFilePath()).parent.parent.parent.path}/app_sdk',
  );
  stdout.writeln('Running flutter test in ${sdkDir.path} ...');
  final r = await Process.run(
    'flutter',
    ['test'],
    workingDirectory: sdkDir.path,
    runInShell: true,
  );
  stdout.write(r.stdout);
  stderr.write(r.stderr);
  if (r.exitCode != 0) {
    stderr.writeln('FAIL: v3 gate/modal unit accept');
    exit(r.exitCode);
  }
  stdout.writeln('PASS: V3 gate + leak_online unit tests');
}
