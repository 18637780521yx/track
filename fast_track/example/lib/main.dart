import 'package:flutter/material.dart';
import 'package:flutter_fast_track/flutter_fast_track.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // FastTrack 仅上报管道（零钩子）。crash/ANR/jank/memory 请用 fast_track_mcp。
  await FastTracker.init(
    url: 'https://track.example.local/v1/events',
    config: const TrackerConfig(dryRun: true, enableDebugLog: true),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastTrack Demo',
      home: Scaffold(
        appBar: AppBar(title: const Text('FastTrack (track only)')),
        body: Center(
          child: FilledButton(
            onPressed: () {
              FastTracker.track('demo_tap', properties: {'screen': 'home'});
            },
            child: const Text('Track demo_tap'),
          ),
        ),
      ),
    );
  }
}
