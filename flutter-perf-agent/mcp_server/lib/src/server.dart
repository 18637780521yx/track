import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'action_runner.dart';
import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'flutter_skill_vm_client.dart';
import 'report_writer.dart';
import 'skill_mcp_bindings.dart';
import 'snapshot_io.dart';

/// MCP tools: UI via flutter_skill (full); metrics via PerfBridge + Sleuth.
///
/// All tool payloads use `{ code, data, msg }`.
base class PerfMcpServer extends MCPServer with ToolsSupport {
  PerfMcpServer(
    super.channel, {
    required this.config,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'flutter-perf-agent',
            version: '0.6.1',
          ),
          instructions:
              'Flutter-Perf-Agent V1 (0.6.1 skill_call + Sleuth). '
              'Prefer: flutter run --profile --no-dds. '
              'Flow: start_perf_test → tap/input_text/scroll → '
              'skill_call / skill_screenshot → get_sleuth_* → stop_perf_test. '
              'All tool JSON: {code, data, msg} (code=0 ok).',
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
    registerTool(_exportTool, _exportSnapshot);
    registerTool(_importTool, _importSnapshot);
    registerTool(_sleuthSnapTool, _getSleuthSnapshot);
    registerTool(_sleuthIssuesTool, _getSleuthIssues);
    registerTool(_sleuthDiagTool, _getSleuthDiagnose);
    registerTool(_sleuthSummaryTool, _getSleuthSummary);
    registerTool(_sleuthRouteTool, _getSleuthRouteHealth);

    registerFlutterSkillTools(
      registerTool: registerTool,
      ensureSkillClient: _ensureSkillClient,
      runner: () => _runner,
      reply: _reply,
    );

    if (config.debugLog) {
      io.stderr.writeln(
        '[flutter-perf-agent-mcp] v0.6.1 bridge=${config.bridgeBaseUrl} '
        'envelope=code/data/msg retries=${config.maxRetries}',
      );
    }
  }

  final PerfAgentConfig config;
  late final BridgeClient _bridge;
  late final ReportWriter _reports;

  PerfSession? _session;
  String? _vmWsUri;
  FlutterSkillClient? _skill;
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

  Future<FlutterSkillClient?> _ensureSkillClient() async {
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
        '启动性能测试会话：清理旧会话，连接 PerfBridge，记录 VM URI（仅供 flutter_skill）。',
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
    description: '停止测试，写出 JSON + HTML（Sleuth/RSS 指标 + 截图）。',
    inputSchema: Schema.object(
      properties: {
        'sessionId': Schema.string(description: '会话 ID（可选）'),
        'exportSnapshot': Schema.bool(description: '是否导出 session_snapshot.json'),
      },
    ),
  );

  final _tapTool = Tool(
    name: 'tap',
    description: 'flutter_skill 点击；前后采 Sleuth/RSS 性能 diff。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(description: '文本或 Key'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
        'useLegacyTap': Schema.bool(description: '强制 legacy tap'),
      },
      required: ['targetDesc'],
    ),
  );

  final _scrollTool = Tool(
    name: 'scroll',
    description: '滑动或滚到目标；前后采 Sleuth/RSS。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(description: '滚到该控件，可选'),
        'direction': Schema.string(description: 'up/down/left/right'),
        'distance': Schema.int(description: '滑动距离'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
      },
    ),
  );

  final _inputTool = Tool(
    name: 'input_text',
    description: '输入文字；前后采 Sleuth/RSS。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(description: '输入框 Key 或标签'),
        'text': Schema.string(description: '要输入的文本'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
      },
      required: ['targetDesc', 'text'],
    ),
  );

  final _uiTool = Tool(
    name: 'get_ui_snapshot',
    description: '获取可交互控件（flutter_skill inspect）。',
    inputSchema: Schema.object(properties: {}),
  );

  final _thresholdTool = Tool(
    name: 'get_perf_threshold_config',
    description: '读取阈值与配置（metricsSource=sleuth）。',
    inputSchema: Schema.object(properties: {}),
  );

  final _exportTool = Tool(
    name: 'export_session_snapshot',
    description: '导出会话快照 JSON（可再 import）。',
    inputSchema: Schema.object(properties: {}),
  );

  final _importTool = Tool(
    name: 'import_session_snapshot',
    description: '导入快照并生成只读 HTML/JSON 报告。',
    inputSchema: Schema.object(
      properties: {
        'snapshotPath': Schema.string(description: 'session_snapshot.json 路径'),
      },
      required: ['snapshotPath'],
    ),
  );

  final _sleuthSnapTool = Tool(
    name: 'get_sleuth_snapshot',
    description: '完整 Sleuth 会话快照（帧/issues/因果/热力/路由等）。',
    inputSchema: Schema.object(
      properties: {
        'compact': Schema.bool(description: 'true 时只返回 markdown 摘要'),
      },
    ),
  );

  final _sleuthIssuesTool = Tool(
    name: 'get_sleuth_issues',
    description: '当前 Sleuth detector issues 列表（含 fixHint）。',
    inputSchema: Schema.object(
      properties: {
        'limit': Schema.int(description: '条数上限，默认 50'),
      },
    ),
  );

  final _sleuthDiagTool = Tool(
    name: 'get_sleuth_diagnose',
    description: 'Sleuth 诊断：initialized / vmConnected / captureMode。',
    inputSchema: Schema.object(properties: {}),
  );

  final _sleuthSummaryTool = Tool(
    name: 'get_sleuth_summary',
    description: 'Sleuth markdown 摘要（可贴 PR/Slack）。',
    inputSchema: Schema.object(
      properties: {
        'topN': Schema.int(description: 'Top issues，默认 5'),
      },
    ),
  );

  final _sleuthRouteTool = Tool(
    name: 'get_sleuth_route_health',
    description: '路由健康分；不传 route 则返回历史列表。',
    inputSchema: Schema.object(
      properties: {
        'routeName': Schema.string(description: '可选路由名'),
      },
    ),
  );

  FutureOr<CallToolResult> _startPerfTest(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final testName = args['testName'] as String? ?? 'unnamed';
    final wait = args['waitStableMs'] as int?;

    await _bridge.stopSession();
    await _disposeSkill();

    final health = await _bridge.health();
    if (!health.isOk || health.data == null) {
      return _reply(health);
    }

    final rawVm = health.data!.vmServiceUri;
    if (rawVm != null && rawVm.isNotEmpty) {
      _vmWsUri = FlutterSkillVmClient.normalizeWsUri(rawVm);
    }

    final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
    final started = await _bridge.startSession(
      testName: testName,
      sessionId: sessionId,
      waitStableMs: wait,
    );
    if (!started.isOk || started.data == null) {
      return _reply(started);
    }

    final startedVm = started.data!.vmServiceUri;
    if (startedVm != null && startedVm.isNotEmpty) {
      _vmWsUri = FlutterSkillVmClient.normalizeWsUri(startedVm);
    }

    _session = PerfSession(
      sessionId: started.data!.sessionId.isNotEmpty
          ? started.data!.sessionId
          : sessionId,
      testName: testName,
      startedAt: DateTime.now(),
      mode: health.data!.mode,
    );
    _stepCounter = 0;

    try {
      await _ensureSkillClient();
    } catch (e) {
      if (config.debugLog) {
        io.stderr.writeln('[flutter-perf-agent-mcp] skill warm failed: $e');
      }
    }

    return _reply(
      ApiResponse.ok({
        'sessionId': _session!.sessionId,
        'testName': testName,
        'mode': health.data!.mode,
        'baseline': started.data!.baseline?.toJson(),
        'bridge': _bridge.bridgeBaseUrl,
        'vmServiceUri': _vmWsUri,
        'uiDriver': 'flutter_skill',
        'metricsSource': 'sleuth_bridge',
        'sleuth': health.data!.sleuth?.toJson(),
        'phase': 'sleuth_full',
        'uiSurface': 'flutter_skill_full',
        'envelope': 'code/data/msg',
        'version': '0.6.0',
      }),
    );
  }

  FutureOr<CallToolResult> _stopPerfTest(CallToolRequest request) async {
    final session = _session;
    if (session == null) return _noSession();

    final args = request.arguments ?? const <String, Object?>{};
    final doExport = args['exportSnapshot'] == true;

    final stop = await _bridge.stopSession();
    final sleuthDiag = await _bridge.sleuthDiagnose();
    final sleuthSum = await _bridge.sleuthSummary(topN: 10);
    final sleuthFinal = await _bridge.sleuthSnapshot();
    String? snapshotPath;
    if (doExport) {
      snapshotPath = await SnapshotIo.exportSession(
        session: session,
        reportsDir: config.reportsDir,
        extra: {
          if (sleuthDiag.data != null) 'sleuthDiagnose': sleuthDiag.toJson(),
          if (sleuthSum.data != null) 'sleuthSummary': sleuthSum.toJson(),
        },
      );
    }
    final paths = await _reports.writeReports(
      session,
      sleuthFinal: sleuthFinal.data,
      sleuthDiagnose: sleuthDiag.data,
      sleuthSummaryMarkdown: sleuthSum.data?.markdown,
    );
    await _disposeSkill();
    final summary = {
      'sessionId': session.sessionId,
      'testName': session.testName,
      'reportPath': paths.jsonPath,
      'htmlReportPath': paths.htmlPath,
      if (snapshotPath != null) 'snapshotPath': snapshotPath,
      'stepCount': session.steps.length,
      'alertCount': session.alerts.length,
      'alerts': session.alerts.map((a) => a.toJson()).toList(),
      'sleuthDiagnose': sleuthDiag.data?.toJson(),
      'sleuthSummaryMarkdown': sleuthSum.data?.markdown,
      'sleuthIssueCount': () {
        final snap = sleuthFinal.data?.snapshot;
        if (snap is Map) {
          return ((snap['currentIssues'] as List?)?.length ??
              (snap['issues'] as List?)?.length);
        }
        return null;
      }(),
      'bridgeStop': stop.toJson(),
      'metricsSource': 'sleuth_bridge',
      'version': '0.6.0',
    };
    _session = null;
    _vmWsUri = null;
    return _reply(ApiResponse.ok(summary));
  }

  FutureOr<CallToolResult> _tap(CallToolRequest request) async {
    final runner = _runner;
    if (runner == null) return _noSession();

    final args = request.arguments ?? const <String, Object?>{};
    final target = (args['targetDesc'] as String? ?? '').trim();
    final wait = args['waitStableMs'] as int?;
    final forceLegacy = args['useLegacyTap'] == true;
    if (target.isEmpty) {
      return _reply(
        ApiResponse.fail(ApiCodes.badRequest, 'targetDesc is required'),
      );
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
    return _stepReply(step);
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
      return _reply(
        ApiResponse.fail(
          ApiCodes.badRequest,
          'provide targetDesc and/or direction(up|down|left|right)',
        ),
      );
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
    return _stepReply(step);
  }

  FutureOr<CallToolResult> _inputText(CallToolRequest request) async {
    final runner = _runner;
    if (runner == null) return _noSession();

    final args = request.arguments ?? const <String, Object?>{};
    final target = (args['targetDesc'] as String? ?? '').trim();
    final text = args['text'] as String? ?? '';
    final wait = args['waitStableMs'] as int?;
    if (target.isEmpty) {
      return _reply(
        ApiResponse.fail(ApiCodes.badRequest, 'targetDesc is required'),
      );
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
    return _stepReply(step);
  }

  FutureOr<CallToolResult> _getUiSnapshot(CallToolRequest request) async {
    final client = await _ensureSkillClient();
    if (client != null) {
      try {
        final inspected = await client.inspectInteractive();
        return _reply(
          ApiResponse.ok({
            'driver': 'flutter_skill',
            'data': inspected,
          }),
        );
      } catch (e) {
        final ui = await _bridge.ui();
        return _reply(
          ApiResponse.ok({
            'driver': 'bridge_fallback',
            'flutterSkillError': e.toString(),
            'ui': ui.data?.toJson(),
          }),
        );
      }
    }

    final ui = await _bridge.ui();
    if (!ui.isOk) return _reply(ui);
    return _reply(
      ApiResponse.ok({
        'driver': 'bridge',
        ...?ui.data?.toJson(),
      }),
    );
  }

  FutureOr<CallToolResult> _getThresholdConfig(CallToolRequest request) {
    return _reply(
      ApiResponse.ok({
        'configPath': config.configPath,
        'bridge': _bridge.bridgeBaseUrl,
        'waitStableMs': config.waitStableMs,
        'postActionSettleMs': config.postActionSettleMs,
        'navigationWaitMs': config.navigationWaitMs,
        'maxRetries': config.maxRetries,
        'captureScreenshots': config.captureScreenshots,
        'metricsSource': 'sleuth_bridge',
        'uiDriver': 'flutter_skill',
        'phase': 'sleuth_full',
        'uiSurface': 'flutter_skill_full',
        'envelope': 'code/data/msg',
        'version': '0.6.0',
        'note':
            'Full Sleuth via Bridge. flutter_skill via tap/scroll/input + '
            'skill_call / skill_screenshot. '
            'For GC/heap: flutter run --profile --no-dds.',
        'thresholds': {
          'maxFrameCostMs': config.maxFrameCostMs,
          'memoryIncreaseWarningMB': config.memoryIncreaseWarningMB,
          'slowRequestMs': config.slowRequestMs,
        },
      }),
    );
  }

  FutureOr<CallToolResult> _getSleuthSnapshot(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    return _reply(
      await _bridge.sleuthSnapshot(compact: args['compact'] == true),
    );
  }

  FutureOr<CallToolResult> _getSleuthIssues(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    return _reply(
      await _bridge.sleuthIssues(
        limit: (args['limit'] as num?)?.toInt() ?? 50,
      ),
    );
  }

  FutureOr<CallToolResult> _getSleuthDiagnose(CallToolRequest request) async {
    return _reply(await _bridge.sleuthDiagnose());
  }

  FutureOr<CallToolResult> _getSleuthSummary(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    return _reply(
      await _bridge.sleuthSummary(
        topN: (args['topN'] as num?)?.toInt() ?? 5,
      ),
    );
  }

  FutureOr<CallToolResult> _getSleuthRouteHealth(
    CallToolRequest request,
  ) async {
    final args = request.arguments ?? const <String, Object?>{};
    return _reply(
      await _bridge.sleuthRouteHealth(
        routeName: args['routeName'] as String?,
      ),
    );
  }

  FutureOr<CallToolResult> _exportSnapshot(CallToolRequest request) async {
    final session = _session;
    if (session == null) return _noSession();
    final path = await SnapshotIo.exportSession(
      session: session,
      reportsDir: config.reportsDir,
    );
    return _reply(ApiResponse.ok({'snapshotPath': path}));
  }

  FutureOr<CallToolResult> _importSnapshot(CallToolRequest request) async {
    final path =
        (request.arguments ?? const {})['snapshotPath'] as String? ?? '';
    if (path.isEmpty) {
      return _reply(
        ApiResponse.fail(ApiCodes.badRequest, 'snapshotPath required'),
      );
    }
    return _reply(
      await SnapshotIo.importSession(
        snapshotPath: path,
        reportsDir: config.reportsDir,
      ),
    );
  }

  CallToolResult _noSession() => _reply(
        ApiResponse.fail(
          ApiCodes.noSession,
          'no active session — call start_perf_test first',
        ),
      );

  CallToolResult _stepReply(StepResult step) {
    final payload = step.toJson(includeScreenshotDataUri: false);
    if (!step.ok) {
      return _reply(
        ApiResponse.fail(
          ApiCodes.actionFailed,
          step.actionResult?.error ?? 'action failed',
          data: payload,
        ),
      );
    }
    return _reply(ApiResponse.ok(payload));
  }

  CallToolResult _reply(ApiResponse<dynamic> response) {
    return CallToolResult(
      isError: !response.isOk,
      content: [
        TextContent(
          text: const JsonEncoder.withIndent('  ').convert(response.toJson()),
        ),
      ],
    );
  }
}
