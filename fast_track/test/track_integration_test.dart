// 集成测试：启动本地接收服务。真实验证请用 example（见 README「本地验证埋点」）。

import 'dart:io';

import 'package:flutter_fast_track/flutter_fast_track.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _port = 9080;
final _trackUrl = 'http://127.0.0.1:$_port/track';

void main() {
  Process? process;

  setUpAll(() async {
    WidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    final script = File('tool/serve_track.dart');
    if (!script.existsSync()) {
      throw StateError('tool/serve_track.dart not found, run from package root');
    }
    final p = await Process.start(
      'dart',
      ['run', 'tool/serve_track.dart', '$_port'],
      workingDirectory: Directory.current.path,
      runInShell: false,
    );
    process = p;
    p.stderr.transform(SystemEncoding().decoder).listen(print);
    p.stdout.transform(SystemEncoding().decoder).listen(print);
    await Future<void>.delayed(const Duration(milliseconds: 800));
  });

  tearDownAll(() {
    process?.kill();
  });

  test('init + track + flush 能成功上报到本地服务', () async {
    await FastTracker.init(
      url: _trackUrl,
      config: const TrackerConfig(
        enableDebugLog: true,
        flushInterval: Duration(hours: 1),
        maxBatchSize: 5,
      ),
    );

    await FastTracker.track('test_event', properties: {'key': 'value'});
    await FastTracker.track('test_event_2');
    await FastTracker.tracker.flush();

    await Future<void>.delayed(const Duration(milliseconds: 500));
    // 无异常即视为通过；服务端会打印收到的 events
  }, skip: 'SpUtils 需 FastTools.init()，后者依赖原生插件；请用 example 验证');
}
