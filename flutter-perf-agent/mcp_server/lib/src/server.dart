import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import 'action_runner.dart';
import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'report_writer.dart';

/// Phase3 MCP tools: start/stop + tap/scroll/input_text + screenshots.
base class PerfMcpServer extends MCPServer with ToolsSupport {
  PerfMcpServer(
    super.channel, {
    required this.config,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'flutter-perf-agent',
            version: '0.3.0',
          ),
          instructions:
              'Flutter-Perf-Agent V1 (Phase3). '
              'Launch example_app (prefer --profile). Then: start_perf_test → '
              'input_text / tap / scroll → stop_perf_test (JSON+HTML+screenshots). '
              'UI via flutter_skill; metrics via PerfBridge+Sleuth.',
        ) {
    _bridge = BridgeClient(config);
    _reports = ReportWriter(config);

    registerTool(_startTool, _startPerfTest);
    registerTool(_stopTool, _stopPerfTest);
    registerTool(_tapTool, _tap);
    registerTool(_scrollTool, _scroll);
    registerTool(_inputTool, _inputText);
    registerTool(_uiTool, _getUiSnapshot);
    registerTool(_thresholdTool, _getThresholdConfig);

    if (config.debugLog) {
      io.stderr.writeln(
        '[flutter-perf-agent-mcp] v0.3.0 bridge=${config.bridgeBaseUrl} '
        'retries=${config.maxRetries} shots=${config.captureScreenshots}',
      );
    }
  }

  final PerfAgentConfig config;
  late final BridgeClient _bridge;
  late final ReportWriter _reports;

  PerfSession? _session;
  String? _vmWsUri;
  FlutterSkillVmClient? _skill;
  int _stepCounter = 0;

  ActionRunner? get _runner {
    final session = _session;
    if (session == null) return null;
    return ActionRunner(
      config: config,
      bridge: _bridge,
      reports: _reports,
      session: session,
      ensureSkillClient: _ensureSkillClient,
      nextStepId: () => ++_stepCounter,
    );
  }

  Future<FlutterSkillVmClient?> _ensureSkillClient() async {
    if (_vmWsUri == null) return null;
    _skill ??= FlutterSkillVmClient(
      _vmWsUri!,
      maxRetries: config.maxRetries,
      retryDelayMs: config.retryDelayMs,
      debugLog: config.debugLog,
    );
    await _skill!.ensureConnected();
    return _skill;
  }

  Future<void> _disposeSkill() async {
    await _skill?.disconnect();
    _skill = null;
  }

  final _startTool = Tool(
    name: 'start_perf_test',
    description:
        '启动性能测试会话：先清理旧会话，连接 PerfBridge，记录 VM URI，读取基线。',
    inputSchema: Schema.object(
      properties: {
        'testName': Schema.string(description: '测试名称'),
        'waitStableMs': Schema.int(description: '页面稳定等待毫秒'),
      },
      required: ['testName'],
    ),
  );

  final _stopTool = Tool(
    name: 'stop_perf_test',
    description: '停止测试，写出 JSON + HTML 报告（含截图），返回路径与告警。',
    inputSchema: Schema.object(
      properties: {
        'sessionId': Schema.string(description: '会话 ID（可选）'),
      },
    ),
  );

  final _tapTool = Tool(
    name: 'tap',
    description:
        'flutter_skill 点击；前后采性能。登录类点击会额外等待页面跳转。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(description: '文本或 Key，如「登录」/ login_button'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
        'useLegacyTap': Schema.bool(description: '强制 legacy tap'),
      },
      required: ['targetDesc'],
    ),
  );

  final _scrollTool = Tool(
    name: 'scroll',
    description:
        '滑动。direction+distance 做 swipe；或 targetDesc 滚到目标。前后采性能。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(description: '滚到该控件（key/text），可选'),
        'direction': Schema.string(
          description: 'up / down / left / right，默认 down',
        ),
        'distance': Schema.int(description: '滑动距离，默认 300'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
      },
    ),
  );

  final _inputTool = Tool(
    name: 'input_text',
    description: '向输入框输入文字（flutter_skill enterText），前后采性能。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(
          description: '输入框 Key 或标签，如 password_field',
        ),
        'text': Schema.string(description: '要输入的文本'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
      },
      required: ['targetDesc', 'text'],
    ),
  );

  final _uiTool = Tool(
    name: 'get_ui_snapshot',
    description: '获取可交互控件（优先 flutter_skill inspect）。',
    inputSchema: Schema.object(properties: {}),
  );

  final _thresholdTool = Tool(
    name: 'get_perf_threshold_config',
    description: '读取性能告警阈值与稳定性配置。',
    inputSchema: Schema.object(properties: {}),
  );

  FutureOr<CallToolResult> _startPerfTest(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final testName = args['testName'] as String? ?? 'unnamed';
    final wait = args['waitStableMs'] as int?;

    // Clear any leftover Bridge session from prior runs / probes.
    await _bridge.stopSession();
    await _disposeSkill();

    final health = await _bridge.health();
    if (health['ok'] != true) return _err(health);

    final rawVm = health['vmServiceUri'] as String?;
    if (rawVm != null && rawVm.isNotEmpty) {
      _vmWsUri = FlutterSkillVmClient.normalizeWsUri(rawVm);
    }

    final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
    final started = await _bridge.startSession(
      testName: testName,
      sessionId: sessionId,
      waitStableMs: wait,
    );
    if (started['ok'] != true) return _err(started);

    final startedVm = started['vmServiceUri'] as String?;
    if (startedVm != null && startedVm.isNotEmpty) {
      _vmWsUri = FlutterSkillVmClient.normalizeWsUri(startedVm);
    }

    _session = PerfSession(
      sessionId: started['sessionId'] as String? ?? sessionId,
      testName: testName,
      startedAt: DateTime.now(),
      mode: health['mode'] as String?,
    );
    _stepCounter = 0;

    // Warm VM connection once per session.
    try {
      await _ensureSkillClient();
    } catch (e) {
      if (config.debugLog) {
        io.stderr.writeln('[flutter-perf-agent-mcp] skill warm failed: $e');
      }
    }

    return _ok({
      'sessionId': _session!.sessionId,
      'testName': testName,
      'mode': health['mode'],
      'baseline': started['baseline'],
      'bridge': config.bridgeBaseUrl,
      'vmServiceUri': _vmWsUri,
      'uiDriver': 'flutter_skill',
      'phase': 'phase3',
      'version': '0.3.0',
    });
  }

  FutureOr<CallToolResult> _stopPerfTest(CallToolRequest request) async {
    final session = _session;
    if (session == null) {
      return _err({
        'ok': false,
        'error': 'no active session — call start_perf_test first',
      });
    }

    final stop = await _bridge.stopSession();
    final paths = await _reports.writeReports(session);
    await _disposeSkill();
    final summary = {
      'sessionId': session.sessionId,
      'testName': session.testName,
      'reportPath': paths.jsonPath,
      'htmlReportPath': paths.htmlPath,
      'stepCount': session.steps.length,
      'alertCount': session.alerts.length,
      'alerts': session.alerts,
      'bridgeStop': stop,
    };
    _session = null;
    _vmWsUri = null;
    return _ok(summary);
  }

  FutureOr<CallToolResult> _tap(CallToolRequest request) async {
    final runner = _runner;
    if (runner == null) return _noSession();

    final args = request.arguments ?? const <String, Object?>{};
    final target = (args['targetDesc'] as String? ?? '').trim();
    final wait = args['waitStableMs'] as int?;
    final forceLegacy = args['useLegacyTap'] == true;
    if (target.isEmpty) {
      return _err({'ok': false, 'error': 'targetDesc is required'});
    }

    final looksLikeNav = _looksLikeNavigationTap(target);
    final step = await runner.run(
      action: 'tap',
      actionLabel: 'tap:$target',
      waitStableMs: wait,
      extraSettleMs: looksLikeNav ? config.navigationWaitMs : 0,
      extraStepFields: {'targetDesc': target},
      skillAction: forceLegacy
          ? (client) async => {'success': false, 'error': 'forced legacy'}
          : (client) => client.tap(text: target, key: target),
      legacyFallback: () => _bridge.tapLegacy(
        targetDesc: target,
        waitStableMs: wait,
      ),
    );
    return step.containsKey('error') && step['ok'] == false
        ? _err(step)
        : _ok(step);
  }

  bool _looksLikeNavigationTap(String target) {
    final t = target.toLowerCase();
    return t.contains('登录') ||
        t.contains('login') ||
        t.contains('submit') ||
        t.contains('下一步') ||
        t.contains('确认');
  }

  FutureOr<CallToolResult> _scroll(CallToolRequest request) async {
    final runner = _runner;
    if (runner == null) return _noSession();

    final args = request.arguments ?? const <String, Object?>{};
    final target = (args['targetDesc'] as String?)?.trim();
    final direction = (args['direction'] as String? ?? 'down').toLowerCase();
    final distance = (args['distance'] as num?)?.toDouble() ?? 300;
    final wait = args['waitStableMs'] as int?;

    if ((target == null || target.isEmpty) &&
        !{'up', 'down', 'left', 'right'}.contains(direction)) {
      return _err({
        'ok': false,
        'error': 'provide targetDesc and/or direction(up|down|left|right)',
      });
    }

    final step = await runner.run(
      action: 'scroll',
      actionLabel: target != null && target.isNotEmpty
          ? 'scroll_to:$target'
          : 'swipe:$direction:$distance',
      waitStableMs: wait,
      extraStepFields: {
        'targetDesc': target,
        'direction': direction,
        'distance': distance,
      },
      skillAction: (client) async {
        if (target != null && target.isNotEmpty) {
          final to = await client.scrollTo(key: target, text: target);
          if (FlutterSkillVmClient.isOk(to)) return to;
        }
        return client.swipe(direction: direction, distance: distance);
      },
    );
    return step.containsKey('error') && step['ok'] == false
        ? _err(step)
        : _ok(step);
  }

  FutureOr<CallToolResult> _inputText(CallToolRequest request) async {
    final runner = _runner;
    if (runner == null) return _noSession();

    final args = request.arguments ?? const <String, Object?>{};
    final target = (args['targetDesc'] as String? ?? '').trim();
    final text = args['text'] as String? ?? '';
    final wait = args['waitStableMs'] as int?;
    if (target.isEmpty) {
      return _err({'ok': false, 'error': 'targetDesc is required'});
    }

    final step = await runner.run(
      action: 'input_text',
      actionLabel: 'input_text:$target',
      waitStableMs: wait,
      extraStepFields: {
        'targetDesc': target,
        'textLength': text.length,
        'textPreview': text.length <= 4 ? text : '${text.substring(0, 2)}***',
      },
      skillAction: (client) => client.enterText(text: text, target: target),
    );
    return step.containsKey('error') && step['ok'] == false
        ? _err(step)
        : _ok(step);
  }

  FutureOr<CallToolResult> _getUiSnapshot(CallToolRequest request) async {
    final client = await _ensureSkillClient();
    if (client != null) {
      try {
        final inspected = await client.inspectInteractive();
        return _ok({
          'ok': true,
          'driver': 'flutter_skill',
          'data': inspected,
        });
      } catch (e) {
        final ui = await _bridge.ui();
        return _ok({
          ...ui,
          'driver': 'bridge_fallback',
          'flutterSkillError': e.toString(),
        });
      }
    }

    final ui = await _bridge.ui();
    if (ui['ok'] != true) return _err(ui);
    return _ok({...ui, 'driver': 'bridge'});
  }

  FutureOr<CallToolResult> _getThresholdConfig(CallToolRequest request) {
    return _ok({
      'configPath': config.configPath,
      'bridge': config.bridgeBaseUrl,
      'waitStableMs': config.waitStableMs,
      'postActionSettleMs': config.postActionSettleMs,
      'navigationWaitMs': config.navigationWaitMs,
      'maxRetries': config.maxRetries,
      'retryDelayMs': config.retryDelayMs,
      'captureScreenshots': config.captureScreenshots,
      'debugLog': config.debugLog,
      'reportsDir': config.reportsDir,
      'uiDriver': 'flutter_skill',
      'phase': 'phase3',
      'version': '0.3.0',
      'thresholds': {
        'maxFrameCostMs': config.maxFrameCostMs,
        'memoryIncreaseWarningMB': config.memoryIncreaseWarningMB,
        'slowRequestMs': config.slowRequestMs,
      },
    });
  }

  CallToolResult _noSession() => _err({
        'ok': false,
        'error': 'no active session — call start_perf_test first',
      });

  CallToolResult _ok(Object data) => CallToolResult(
        content: [
          TextContent(text: const JsonEncoder.withIndent('  ').convert(data)),
        ],
      );

  CallToolResult _err(Object data) => CallToolResult(
        isError: true,
        content: [
          TextContent(text: const JsonEncoder.withIndent('  ').convert(data)),
        ],
      );
}
