import 'package:flutter_fast_track/flutter_fast_track.dart';
import 'package:fast_tools/fast_tools.dart';
import 'package:flutter/material.dart';

// 接收服务地址。模拟器/真机必须用电脑的局域网 IP，否则会 Connection refused。
// 方式一：运行时传参（推荐）flutter run --dart-define=TRACK_HOST=192.168.1.100
// 方式二：改下面 _trackHost。查本机 IP：ifconfig | grep "inet "
const _trackHost = String.fromEnvironment('TRACK_HOST', defaultValue: '127.0.0.1');
const _trackPort = 8080;
String get _trackUrl => 'http://$_trackHost:$_trackPort/track';

/// 故意不可达的地址，用于演示失败重试（控制台可见 retry #2/#3/#4 等）
const _retryDemoUrl = 'http://127.0.0.1:19999/track';

const _demoConfig = TrackerConfig(
  enableDebugLog: true,
  flushInterval: Duration(seconds: 10),
  maxBatchSize: 5,
  maxCachedEvents: 1000,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先 init 再 run，这样生命周期/异常自动埋点才能上报
  await FastTracker.init(url: _trackUrl, config: _demoConfig);
  await FastTrackCrashHandler.run(() async {
    final lifecycleObserver = FastTrackLifecycleObserver();
    final navigatorObserver = FastTrackNavigatorObserver();
    runApp(MyApp(
      // lifecycleObserver: lifecycleObserver,
      navigatorObserver: navigatorObserver,
    ));
    // 首帧后启动生命周期监听，触发 app_start / 首次启动 / 日活
    WidgetsBinding.instance.addPostFrameCallback((_) => lifecycleObserver.start());
  });
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    // required this.lifecycleObserver,
    required this.navigatorObserver,
  });

  // final FastTrackLifecycleObserver lifecycleObserver;
  final FastTrackNavigatorObserver navigatorObserver;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fast_track 示例',
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
      navigatorObservers: [navigatorObserver],
      routes: {
        '/detail': (context) => const DetailPage(),
      },
    );
  }
}

/// 用于触发 page_view / page_stay 的二级页
class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('详情页')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('进入此页会打 page_view，返回会打 page_stay'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _inited = true; // main 里已 init，默认视为已初始化
  String _status = '已初始化（main 中已 init，自动埋点已开启）';

  Future<void> _init({String? url, TrackerConfig? config}) async {
    final targetUrl = url ?? _trackUrl;
    final cfg = config ?? _demoConfig;
    try {
      await FastTracker.init(
        url: targetUrl,
        config: cfg,
      );
      setState(() {
        _inited = true;
        _status = url == null ? '已初始化，上报地址: $targetUrl' : '已切到: $targetUrl';
      });
    } catch (e) {
      setState(() => _status = '初始化失败: $e');
    }
  }

  /// 演示失败重试：切到不可达地址 → 埋点 → flush，控制台可见重试日志
  Future<void> _demoRetry() async {
    if (!_inited) return;
    await _init(url: _retryDemoUrl);
    if (!mounted) return;
    FastTracker.track('retry_demo', properties: {'from': 'example'});
    await FastTracker.tracker.flush();
    if (!mounted) return;
    setState(() => _status = '失败重试已触发，请查看控制台（retry 1/5, 2/5…）');
  }

  /// 演示批量上报：连续埋点 5 条（=maxBatchSize），会触发一次自动 flush
  void _demoBatch() {
    if (!_inited) return;
    for (var i = 0; i < 5; i++) {
      FastTracker.track('batch_demo', properties: {'from': 'example', 'index': i});
    }
    setState(() => _status = '已连续埋点 5 条（满批会自动上报），可再点「立即 flush」');
  }

  /// 演示队列溢出：埋点超过 maxCachedEvents(1000)，最老的会被丢弃，控制台有 queue overflow
  Future<void> _demoOverflow() async {
    if (!_inited) return;
    setState(() => _status = '正在埋点 1005 条…');
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 1005; i++) {
      FastTracker.track('overflow_demo', properties: {'i': i});
    }
    if (!mounted) return;
    setState(() => _status = '已埋点 1005 条（超过 1000 会丢最老 5 条），看控制台 queue overflow');
  }

  /// 演示 gzip 压缩上报：用 compressRequest: true 重新 init，再埋点+flush
  Future<void> _demoCompress() async {
    if (!_inited) return;
    await _init(
      config: const TrackerConfig(
        enableDebugLog: true,
        flushInterval: Duration(seconds: 10),
        maxBatchSize: 5,
        compressRequest: true,
      ),
    );
    if (!mounted) return;
    FastTracker.track('compress_demo', properties: {'from': 'example'});
    await FastTracker.tracker.flush();
    if (!mounted) return;
    setState(() => _status = '已用 gzip 上报 1 条，服务端会解压并打印');
  }

  void _track(String name) {
    if (!_inited) return;
    FastTracker.track(name, properties: {'from': 'example', 't': DateTime.now().toIso8601String()});
    setState(() => _status = '已发送: $name');
  }

  Future<void> _flush() async {
    if (!_inited) return;
    await FastTracker.tracker.flush();
    setState(() => _status = '已 flush');
  }

  /// 触发未捕获异常，用于验证 app_crash 上报（会红屏，先 flush 再点）
  void _demoCrash() {
    Future.microtask(() => throw Exception('example_demo_crash'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('fast_track 示例')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _inited ? null : _init,
              child: Text(_inited ? '已初始化' : '初始化（连接本地服务）'),
            ),
            if (_inited) ...[
              const SizedBox(height: 8),
              const Text('自动埋点（已开启）', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              const Text(
                '启动: app_start；首次: app_first_open；日活: app_daily_active；'
                '前后台: app_foreground/background；未捕获异常: app_crash。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 4),
              FilledButton.tonal(
                onPressed: () => Navigator.of(context).pushNamed('/detail'),
                child: const Text('打开详情页（测 page_view / page_stay）'),
              ),
              FilledButton.tonal(
                onPressed: _demoCrash,
                child: const Text('触发异常（测 app_crash，会红屏）'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                  onPressed: () => _track('btn_click'), child: const Text('埋点: btn_click')),
              FilledButton.tonal(
                  onPressed: () => _track('page_view'), child: const Text('埋点: page_view')),
              FilledButton.tonal(onPressed: _flush, child: const Text('立即 flush')),
              const SizedBox(height: 16),
              const Text('批量上报', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              FilledButton.tonal(onPressed: _demoBatch, child: const Text('连续埋点 5 条（满批自动上报）')),
              const SizedBox(height: 16),
              const Text('队列溢出', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              FilledButton.tonal(
                  onPressed: _demoOverflow, child: const Text('埋点 1005 条（超 1000 丢最老）')),
              const SizedBox(height: 16),
              const Text('压缩上报', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              FilledButton.tonal(onPressed: _demoCompress, child: const Text('gzip 上报 1 条')),
              const SizedBox(height: 16),
              const Text('失败重试', style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              FilledButton.tonal(
                onPressed: _demoRetry,
                child: const Text('触发失败重试（看控制台）'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _init(),
                child: const Text('恢复正常地址/配置'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
