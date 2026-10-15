import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_perf_agent/flutter_perf_agent.dart';
import 'package:sleuth/sleuth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kReleaseMode) {
    await PerfAgent.ensureInitialized(
      host: '127.0.0.1',
      port: 19288,
      waitStableMs: 500,
    );
  }

  runApp(
    Sleuth.track(
      child: const PerfDemoApp(),
      config: const SleuthConfig(
        fpsTarget: 60,
        enableNetworkMonitoring: true,
      ),
    ),
  );
}

class PerfDemoApp extends StatelessWidget {
  const PerfDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Perf Agent Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E4F)),
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController(text: 'test@test.com');
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _login() {
    if (_password.text.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    setState(() => _error = null);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Perf Agent Demo',
                  key: const Key('brand_title'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Phase2：登录 → 首页 → 滑动列表',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Semantics(
                  label: '账号输入框',
                  textField: true,
                  child: TextField(
                    key: const Key('email_field'),
                    controller: _email,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  label: '密码输入框',
                  textField: true,
                  child: TextField(
                    key: const Key('password_field'),
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 20),
                Semantics(
                  label: '登录按钮',
                  button: true,
                  child: FilledButton(
                    key: const Key('login_button'),
                    onPressed: _login,
                    child: const Text('登录'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('首页', key: Key('home_title')),
      ),
      body: Semantics(
        label: '首页列表',
        child: ListView.builder(
          key: const Key('home_list'),
          itemCount: 60,
          itemBuilder: (context, index) {
            // Intentionally a bit heavy to exercise jank/FPS during scroll.
            return ListTile(
              key: Key('list_item_$index'),
              leading: CircleAvatar(child: Text('$index')),
              title: Text('列表项 #$index'),
              subtitle: Text('Phase2 滑动性能测试 · item $index'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            );
          },
        ),
      ),
      floatingActionButton: Semantics(
        label: '刷新按钮',
        button: true,
        child: FloatingActionButton(
          key: const Key('refresh_button'),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已刷新')),
            );
          },
          child: const Icon(Icons.refresh),
        ),
      ),
    );
  }
}
