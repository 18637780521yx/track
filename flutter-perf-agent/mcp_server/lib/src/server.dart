import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import 'bridge_client.dart';
import 'config.dart';
import 'report_writer.dart';

/// Phase1 MCP tools: start_perf_test / stop_perf_test / tap / get_ui_snapshot.
base class PerfMcpServer extends MCPServer with ToolsSupport {
  PerfMcpServer(
    super.channel, {
    required this.config,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'flutter-perf-agent',
            version: '0.1.0',
          ),
          instructions:
              'Flutter UI automation + Sleuth performance capture. '
              '1) Launch example_app (profile). 2) start_perf_test. '
              '3) tap. 4) stop_perf_test to get JSON report.',
        ) {
    _bridge = BridgeClient(config);
    _reports = ReportWriter(config);

    registerTool(_startTool, _startPerfTest);
    registerTool(_stopTool, _stopPerfTest);
    registerTool(_tapTool, _tap);
    registerTool(_uiTool, _getUiSnapshot);
    registerTool(_thresholdTool, _getThresholdConfig);
  }

  final PerfAgentConfig config;
  late final BridgeClient _bridge;
  late final ReportWriter _reports;

  PerfSession? _session;
  int _stepCounter = 0;

  final _startTool = Tool(
    name: 'start_perf_test',
    description:
        '启动性能测试会话：连接 App 内 PerfBridge，重置会话并读取基线性能快照。',
    inputSchema: Schema.object(
      properties: {
        'testName': Schema.string(description: '测试名称'),
        'waitStableMs': Schema.int(
          description: '页面稳定等待毫秒，默认读配置',
        ),
      },
      required: ['testName'],
    ),
  );

  final _stopTool = Tool(
    name: 'stop_perf_test',
    description: '停止测试，汇总步骤与告警，写出 JSON 报告并返回路径与摘要。',
    inputSchema: Schema.object(
      properties: {
        'sessionId': Schema.string(description: '会话 ID（可选，默认当前会话）'),
      },
    ),
  );

  final _tapTool = Tool(
    name: 'tap',
    description:
        '点击控件（语义树定位）。操作前后自动采集 Sleuth/RSS 性能快照并计算 diff。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(
          description: '控件描述，例如「登录」或「登录按钮」',
        ),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
      },
      required: ['targetDesc'],
    ),
  );

  final _uiTool = Tool(
    name: 'get_ui_snapshot',
    description: '获取当前可交互语义节点列表，供 LLM 分析页面状态。',
    inputSchema: Schema.object(properties: {}),
  );

  final _thresholdTool = Tool(
    name: 'get_perf_threshold_config',
    description: '读取性能告警阈值配置。',
    inputSchema: Schema.object(properties: {}),
  );

  FutureOr<CallToolResult> _startPerfTest(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final testName = args['testName'] as String? ?? 'unnamed';
    final wait = args['waitStableMs'] as int?;

    final health = await _bridge.health();
    if (health['ok'] != true) {
      return _err(health);
    }

    final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
    final started = await _bridge.startSession(
      testName: testName,
      sessionId: sessionId,
      waitStableMs: wait,
    );
    if (started['ok'] != true) {
      return _err(started);
    }

    _session = PerfSession(
      sessionId: started['sessionId'] as String? ?? sessionId,
      testName: testName,
      startedAt: DateTime.now(),
      mode: health['mode'] as String?,
    );
    _stepCounter = 0;

    return _ok({
      'sessionId': _session!.sessionId,
      'testName': testName,
      'mode': health['mode'],
      'baseline': started['baseline'],
      'bridge': config.bridgeBaseUrl,
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
    final path = await _reports.writeJson(session);
    final summary = {
      'sessionId': session.sessionId,
      'testName': session.testName,
      'reportPath': path,
      'stepCount': session.steps.length,
      'alertCount': session.alerts.length,
      'alerts': session.alerts,
      'bridgeStop': stop,
    };
    _session = null;
    return _ok(summary);
  }

  FutureOr<CallToolResult> _tap(CallToolRequest request) async {
    final session = _session;
    if (session == null) {
      return _err({
        'ok': false,
        'error': 'no active session — call start_perf_test first',
      });
    }

    final args = request.arguments ?? const <String, Object?>{};
    final target = args['targetDesc'] as String? ?? '';
    final wait = args['waitStableMs'] as int?;
    if (target.trim().isEmpty) {
      return _err({'ok': false, 'error': 'targetDesc is required'});
    }

    final result = await _bridge.tap(targetDesc: target, waitStableMs: wait);
    _stepCounter += 1;
    final stepId = 'step_$_stepCounter';
    final diff = (result['diff'] as Map?)?.cast<String, dynamic>() ?? {};
    final alerts = _reports.evaluateDiff(
      diff,
      stepId: stepId,
      action: 'tap:$target',
    );
    for (final a in alerts) {
      session.addAlert(a);
    }

    final step = {
      'stepId': stepId,
      'action': 'tap',
      'targetDesc': target,
      'ok': result['ok'] == true,
      'actionResult': result['action'],
      'diff': diff,
      'alerts': alerts,
      'at': DateTime.now().toIso8601String(),
    };
    session.addStep(step);

    return _ok(step);
  }

  FutureOr<CallToolResult> _getUiSnapshot(CallToolRequest request) async {
    final ui = await _bridge.ui();
    if (ui['ok'] != true) return _err(ui);
    return _ok(ui);
  }

  FutureOr<CallToolResult> _getThresholdConfig(CallToolRequest request) {
    return _ok({
      'configPath': config.configPath,
      'bridge': config.bridgeBaseUrl,
      'waitStableMs': config.waitStableMs,
      'reportsDir': config.reportsDir,
      'thresholds': {
        'maxFrameCostMs': config.maxFrameCostMs,
        'memoryIncreaseWarningMB': config.memoryIncreaseWarningMB,
        'slowRequestMs': config.slowRequestMs,
      },
    });
  }

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
