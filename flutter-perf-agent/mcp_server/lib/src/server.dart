import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import 'action_runner.dart';
import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'report_writer.dart';
import 'skill_mcp_bindings.dart';
import 'snapshot_io.dart';

/// MCP tools: UI via flutter_skill (full); metrics via PerfBridge + Sleuth.
base class PerfMcpServer extends MCPServer with ToolsSupport {
  PerfMcpServer(
    super.channel, {
    required this.config,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'flutter-perf-agent',
            version: '0.5.1',
          ),
          instructions:
              'Flutter-Perf-Agent V1 (0.5.1 Sleuth + full flutter_skill). '
              'Prefer: flutter run --profile --no-dds. '
              'Flow: start_perf_test → tap/input_text/scroll/skill_* → '
              'get_sleuth_issues / get_sleuth_diagnose → stop_perf_test. '
              'UI: full flutter_skill (skill_* + tap/scroll/input). '
              'Metrics: full Sleuth via PerfBridge.',
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
      ok: _ok,
      err: _err,
    );

    if (config.debugLog) {
      io.stderr.writeln(
        '[flutter-perf-agent-mcp] v0.5.1 bridge=${config.bridgeBaseUrl} '
        'metrics=sleuth_full ui=flutter_skill_full '
        'retries=${config.maxRetries}',
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
      'metricsSource': 'sleuth_bridge',
      'sleuth': health['sleuth'],
      'phase': 'sleuth_full',
      'uiSurface': 'flutter_skill_full',
      'version': '0.5.1',
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

    final args = request.arguments ?? const <String, Object?>{};
    final doExport = args['exportSnapshot'] == true;

    final stop = await _bridge.stopSession();
    final sleuthDiag = await _bridge.sleuthDiagnose();
    final sleuthSum = await _bridge.sleuthSummary(topN: 10);
    // Full snapshot can be large — keep for report artifact, trim in MCP reply.
    final sleuthFinal = await _bridge.sleuthSnapshot();
    String? snapshotPath;
    if (doExport) {
      snapshotPath = await SnapshotIo.exportSession(
        session: session,
        reportsDir: config.reportsDir,
        extra: {
          'sleuthDiagnose': sleuthDiag,
          'sleuthSummary': sleuthSum,
        },
      );
    }
    final paths = await _reports.writeReports(
      session,
      sleuthFinal: sleuthFinal,
      sleuthDiagnose: sleuthDiag,
      sleuthSummaryMarkdown: sleuthSum['markdown'] as String?,
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
      'alerts': session.alerts,
      'sleuthDiagnose': sleuthDiag,
      'sleuthSummaryMarkdown': sleuthSum['markdown'],
      'sleuthIssueCount': (sleuthFinal['snapshot'] is Map)
          ? ((sleuthFinal['snapshot']['currentIssues'] as List?)?.length ??
              (sleuthFinal['snapshot']['issues'] as List?)?.length)
          : null,
      'bridgeStop': stop,
      'metricsSource': 'sleuth_bridge',
      'version': '0.5.1',
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
      'captureScreenshots': config.captureScreenshots,
      'metricsSource': 'sleuth_bridge',
      'uiDriver': 'flutter_skill',
      'phase': 'sleuth_full',
      'uiSurface': 'flutter_skill_full',
      'version': '0.5.1',
      'note':
          'Full Sleuth via Bridge. Full flutter_skill via skill_* tools. '
          'For GC/heap: flutter run --profile --no-dds. '
          'VM used for flutter_skill UI.',
      'thresholds': {
        'maxFrameCostMs': config.maxFrameCostMs,
        'memoryIncreaseWarningMB': config.memoryIncreaseWarningMB,
        'slowRequestMs': config.slowRequestMs,
      },
    });
  }

  FutureOr<CallToolResult> _getSleuthSnapshot(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final r = await _bridge.sleuthSnapshot(compact: args['compact'] == true);
    return r['ok'] == true ? _ok(r) : _err(r);
  }

  FutureOr<CallToolResult> _getSleuthIssues(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final r = await _bridge.sleuthIssues(
      limit: (args['limit'] as num?)?.toInt() ?? 50,
    );
    return r['ok'] == true ? _ok(r) : _err(r);
  }

  FutureOr<CallToolResult> _getSleuthDiagnose(CallToolRequest request) async {
    final r = await _bridge.sleuthDiagnose();
    return r['ok'] == true ? _ok(r) : _err(r);
  }

  FutureOr<CallToolResult> _getSleuthSummary(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final r = await _bridge.sleuthSummary(
      topN: (args['topN'] as num?)?.toInt() ?? 5,
    );
    return r['ok'] == true ? _ok(r) : _err(r);
  }

  FutureOr<CallToolResult> _getSleuthRouteHealth(
    CallToolRequest request,
  ) async {
    final args = request.arguments ?? const <String, Object?>{};
    final r = await _bridge.sleuthRouteHealth(
      routeName: args['routeName'] as String?,
    );
    return r['ok'] == true ? _ok(r) : _err(r);
  }

  FutureOr<CallToolResult> _exportSnapshot(CallToolRequest request) async {
    final session = _session;
    if (session == null) return _noSession();
    final path = await SnapshotIo.exportSession(
      session: session,
      reportsDir: config.reportsDir,
    );
    return _ok({'ok': true, 'snapshotPath': path});
  }

  FutureOr<CallToolResult> _importSnapshot(CallToolRequest request) async {
    final path =
        (request.arguments ?? const {})['snapshotPath'] as String? ?? '';
    if (path.isEmpty) {
      return _err({'ok': false, 'error': 'snapshotPath required'});
    }
    final r = await SnapshotIo.importSession(
      snapshotPath: path,
      reportsDir: config.reportsDir,
    );
    return r['ok'] == true ? _ok(r) : _err(r);
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
