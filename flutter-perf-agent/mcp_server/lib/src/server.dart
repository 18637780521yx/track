import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'action_runner.dart';
import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'flutter_skill_vm_client.dart';
import 'report_writer.dart';
import 'skill_mcp_bindings.dart';
import 'snapshot_io.dart';
import 'visibility_assist.dart';

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
            version: '0.9.3',
          ),
          instructions:
              'Flutter-Perf-Agent V1 (0.9.4 inline alerts). '
              'Prefer: flutter run --profile --no-dds. '
              'UI tools (tap/input_text/scroll/skill_call) AUTO-start a perf '
              'session: each action samples Sleuth/RSS, updates live report. '
              'Call stop_perf_test for final HTML/JSON. '
              'Optional explicit start_perf_test. '
              'Timeline: lifecycle / page / transition; alerts inline after actions; '
              'auto screenshots off; use tool screenshot for on-demand capture. '
              'tap defaults scrollIntoView (tree≠viewport); '
              'get_ui_snapshot marks needsScroll/offScreenTexts. '
              'After flutter run: wait_lifecycle (health.lifecycleForeground). '
              'All tool JSON: {code, data, msg} (code=0 ok).',
        ) {
    _bridge = BridgeClient(config);
    _reports = ReportWriter(config);

    registerTool(_startTool, _startPerfTest);
    registerTool(_stopTool, _stopPerfTest);
    registerTool(_waitLifecycleTool, _waitLifecycle);
    registerTool(_tapTool, _tap);
    registerTool(_scrollTool, _scroll);
    registerTool(_inputTool, _inputText);
    registerTool(_screenshotTool, _screenshot);
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
      ensureSession: _ensureSessionForAction,
      runner: () => _runner,
      afterStep: _afterStep,
      reply: _reply,
    );

    if (config.debugLog) {
      io.stderr.writeln(
        '[flutter-perf-agent-mcp] v0.9.2 bridge=${config.bridgeBaseUrl} '
        'autoSession=true envelope=code/data/msg '
        'retries=${config.maxRetries} '
        'captureScreenshots=${config.captureScreenshots}',
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
    if (_vmWsUri == null) {
      await _warmVmFromBridge();
    }
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

  Future<void> _warmVmFromBridge() async {
    final health = await _bridge.health();
    final rawVm = health.data?.vmServiceUri;
    if (rawVm != null && rawVm.isNotEmpty) {
      _vmWsUri = FlutterSkillVmClient.normalizeWsUri(rawVm);
    }
  }

  Future<void> _disposeSkill() async {
    await _skill?.disconnect();
    _skill = null;
  }

  /// UI 动作前：无会话则自动开会话（采点 + live 报告）。
  Future<ApiResponse<void>> _ensureSessionForAction({
    String? testName,
  }) async {
    if (_session != null) return ApiResponse.ok(null);
    final name = testName ??
        'auto_${DateTime.now().toIso8601String().replaceAll(':', '-')}';
    final err = await _beginSession(testName: name);
    if (err != null) return err;
    if (config.debugLog) {
      io.stderr.writeln(
        '[flutter-perf-agent-mcp] auto-started session '
        '${_session?.sessionId} ($name)',
      );
    }
    return ApiResponse.ok(null);
  }

  /// 返回失败信封；成功返回 null。
  Future<ApiResponse<void>?> _beginSession({
    required String testName,
    int? waitStableMs,
    bool resetExisting = false,
  }) async {
    if (resetExisting || _session != null) {
      await _disposeSkill();
      _session = null;
      _vmWsUri = null;
      _stepCounter = 0;
    }
    // 清掉 App 侧残留 Bridge session（不落报告，避免空会话脏文件）。
    await _bridge.stopSession(writeReport: false);

    final health = await _bridge.health();
    if (!health.isOk || health.data == null) {
      return ApiResponse.fail(
        health.code == ApiCodes.ok ? ApiCodes.unavailable : health.code,
        health.msg,
      );
    }

    final rawVm = health.data!.vmServiceUri;
    if (rawVm != null && rawVm.isNotEmpty) {
      _vmWsUri = FlutterSkillVmClient.normalizeWsUri(rawVm);
    }

    final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
    final reportsAbs = io.File(config.reportsDir).isAbsolute
        ? config.reportsDir
        : io.File(config.reportsDir).absolute.path;
    final started = await _bridge.startSession(
      testName: testName,
      sessionId: sessionId,
      waitStableMs: waitStableMs,
      reportsDir: reportsAbs,
      manualRecording: true,
    );
    if (!started.isOk || started.data == null) {
      return ApiResponse.fail(started.code, started.msg);
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

    // Cold-start step first (TTFF + first route shot); never merges with login.
    try {
      final runner = _runner;
      if (runner != null) {
        final land = await runner.recordColdStart(
          onAfterRelaunch: () async {
            await _disposeSkill();
            _vmWsUri = null;
            await _warmVmFromBridge();
          },
        );
        await _afterStep(land);
      }
    } catch (e) {
      if (config.debugLog) {
        io.stderr.writeln(
          '[flutter-perf-agent-mcp] cold_start step failed: $e',
        );
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _afterStep(StepResult step) async {
    final session = _session;
    if (session == null) return {};
    try {
      // Prefer App SDK live (same HTML as manual); mirror already refreshed it.
      final live = await _bridge.writeLiveReport();
      if (live.isOk && live.data != null) {
        final d = live.data!;
        return {
          'liveReportPath': d['liveJsonPath'],
          'liveHtmlReportPath': d['liveHtmlPath'],
          'sessionId': d['sessionId'] ?? session.sessionId,
          'stepCount': d['stepCount'] ?? session.steps.length,
          'alertCount': session.alerts.length,
          'reportOwner': 'app_sdk',
        };
      }
      // Fallback: MCP-side live if bridge journal unavailable.
      final mcpLive = await _reports.writeLiveReports(session);
      return {
        'liveReportPath': mcpLive.jsonPath,
        'liveHtmlReportPath': mcpLive.htmlPath,
        'sessionId': session.sessionId,
        'stepCount': session.steps.length,
        'alertCount': session.alerts.length,
        'reportOwner': 'mcp_server',
      };
    } catch (e) {
      if (config.debugLog) {
        io.stderr.writeln('[flutter-perf-agent-mcp] live report failed: $e');
      }
      return {'liveReportError': e.toString()};
    }
  }

  final _startTool = Tool(
    name: 'start_perf_test',
    description:
        '显式启动性能测试会话（可选）。tap/input_text/scroll/skill_call '
        '在无会话时会自动开会话并逐步更新 live 报告。',
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
    description:
        '结束会话并写出最终 JSON + HTML（含步骤/告警/截图）。'
        '过程中已有 live_*.json/html。',
    inputSchema: Schema.object(
      properties: {
        'sessionId': Schema.string(description: '会话 ID（可选）'),
        'exportSnapshot': Schema.bool(description: '是否导出 session_snapshot.json'),
      },
    ),
  );

  final _waitLifecycleTool = Tool(
    name: 'wait_lifecycle',
    description:
        '轮询 Bridge /health 上的 App 生命周期，直到 cold_start 或 foreground '
        '（非盲等固定秒数）。flutter run / 冷启动后先调此工具再 tap。',
    inputSchema: Schema.object(
      properties: {
        'timeoutMs': Schema.int(description: '超时毫秒，默认 120000'),
        'pollMs': Schema.int(description: '轮询间隔毫秒，默认 300'),
      },
    ),
  );

  final _tapTool = Tool(
    name: 'tap',
    description:
        'flutter_skill 点击；默认先 scrollIntoView（树里有≠屏上可见，短屏需上滑）。'
        '无会话时自动开会话；前后采 Sleuth/RSS，并更新 live 报告。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(description: '文本或 Key'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
        'useLegacyTap': Schema.bool(description: '强制 legacy tap'),
        'scrollIntoView': Schema.bool(
          description: '点击前滚入视口；默认 true。勿把 hittable=false 当成功能关闭',
        ),
      },
      required: ['targetDesc'],
    ),
  );

  final _scrollTool = Tool(
    name: 'scroll',
    description: '滑动或滚到目标；自动会话 + Sleuth/RSS 采样 + live 报告。',
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
    description: '输入文字；自动会话 + Sleuth/RSS 采样 + live 报告。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(description: '输入框 Key 或标签'),
        'text': Schema.string(description: '要输入的文本'),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
      },
      required: ['targetDesc', 'text'],
    ),
  );

  final _screenshotTool = Tool(
    name: 'screenshot',
    description:
        '按需全屏截图（与 tap 自动截图无关；captureScreenshots 默认关闭不影响本工具）。'
        '保存 PNG 到 reports/screenshots，返回路径；可选附带 base64。'
        '区域/控件截图用 skill_call method=screenshotRegion|screenshotElement。',
    inputSchema: Schema.object(
      properties: {
        'maxWidth': Schema.int(description: '默认 720'),
        'includeDataUri': Schema.bool(
          description: '是否在 data 中返回 data:image/png;base64,...（默认 false，载荷大）',
        ),
        'name': Schema.string(description: '文件名（不含扩展名），可选'),
      },
    ),
  );

  final _uiTool = Tool(
    name: 'get_ui_snapshot',
    description:
        '获取可交互控件，并标注 inViewport / needsScroll / offScreenTexts。'
        '树里能找到但 needsScroll=true 时，应先 scroll/tap(scrollIntoView)，'
        '不要当成按钮被业务隐藏。',
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

    final err = await _beginSession(
      testName: testName,
      waitStableMs: wait,
      resetExisting: true,
    );
    if (err != null) return _reply(err);

    final health = await _bridge.health();
    return _reply(
      ApiResponse.ok({
        'sessionId': _session!.sessionId,
        'testName': testName,
        'mode': _session!.mode ?? health.data?.mode,
        'bridge': _bridge.bridgeBaseUrl,
        'vmServiceUri': _vmWsUri,
        'uiDriver': 'flutter_skill',
        'metricsSource': 'sleuth_bridge',
        'sleuth': health.data?.sleuth?.toJson(),
        'autoPerf': true,
        'note':
            'Steps are route visits (same-route actions merge). '
            'tap/input/scroll/skill_call update live report; '
            'call stop_perf_test for final report.',
        'envelope': 'code/data/msg',
        'version': '0.6.3',
      }),
    );
  }

  FutureOr<CallToolResult> _stopPerfTest(CallToolRequest request) async {
    final session = _session;
    if (session == null) return _noSession();

    final args = request.arguments ?? const <String, Object?>{};
    final doExport = args['exportSnapshot'] == true;

    // Ensure network logs land in the MCP-side copy even if step-time missed.
    await _backfillStepNetwork(session);
    final sleuthDiag = await _bridge.sleuthDiagnose();
    final sleuthSum = await _bridge.sleuthSummary(topN: 10);
    final sleuthFinal = await _bridge.sleuthSnapshot();

    // App SDK journal is authoritative (same HTML/schema as manual).
    final stop = await _bridge.stopSession(writeReport: true);

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

    final sdkJson = stop.data?.reportJsonPath;
    final sdkHtml = stop.data?.reportHtmlPath;
    // Fallback only if SDK journal empty / bridge failed.
    ReportPaths? mcpFallback;
    if (sdkJson == null || sdkHtml == null) {
      mcpFallback = await _reports.writeReports(
        session,
        sleuthFinal: sleuthFinal.data,
        sleuthDiagnose: sleuthDiag.data,
        sleuthSummaryMarkdown: sleuthSum.data?.markdown,
      );
    }
    await _disposeSkill();
    final summary = {
      'sessionId': session.sessionId,
      'testName': session.testName,
      'reportPath': sdkJson ?? mcpFallback?.jsonPath,
      'htmlReportPath': sdkHtml ?? mcpFallback?.htmlPath,
      'reportOwner': sdkJson != null ? 'app_sdk' : 'mcp_server',
      if (sdkJson != null) 'sdkReportPath': sdkJson,
      if (sdkHtml != null) 'sdkHtmlReportPath': sdkHtml,
      if (mcpFallback != null) 'mcpReportPath': mcpFallback.jsonPath,
      if (mcpFallback != null) 'mcpHtmlReportPath': mcpFallback.htmlPath,
      if (snapshotPath != null) 'snapshotPath': snapshotPath,
      'stepCount': stop.data?.stepCount ?? session.steps.length,
      'alertCount': stop.data?.alertCount ?? session.alerts.length,
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
      'version': '0.8.2',
      'note': '报告权威在 App SDK（与手动同款 HTML）；MCP 仅在 SDK 失败时回退写出。',
    };
    _session = null;
    _vmWsUri = null;
    return _reply(ApiResponse.ok(summary));
  }

  /// Poll Bridge health until App lifecycle is cold_start / foreground.
  FutureOr<CallToolResult> _waitLifecycle(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 120000;
    final pollMs = (args['pollMs'] as num?)?.toInt() ?? 300;
    final t0 = DateTime.now();
    final deadline = t0.add(Duration(milliseconds: timeoutMs));

    while (DateTime.now().isBefore(deadline)) {
      try {
        await _bridge.ensureResolved(force: true);
        final health = await _bridge.health();
        final data = health.data;
        if (health.isOk && data != null && data.lifecycleForeground) {
          // Warm VM for subsequent tap/screenshot.
          final rawVm = data.vmServiceUri;
          if (rawVm != null && rawVm.isNotEmpty) {
            _vmWsUri = FlutterSkillVmClient.normalizeWsUri(rawVm);
          }
          final ms = DateTime.now().difference(t0).inMilliseconds;
          return _reply(
            ApiResponse.ok({
              'ready': true,
              'elapsedMs': ms,
              'lifecycle': data.lifecycle,
              'lifecycleForeground': true,
              'vmServiceUri': data.vmServiceUri,
              'bridge': _bridge.bridgeBaseUrl,
              'note': 'App lifecycle cold_start/foreground — 可开始 tap',
            }),
          );
        }
      } catch (e) {
        if (config.debugLog) {
          io.stderr.writeln('[flutter-perf-agent-mcp] wait_lifecycle: $e');
        }
      }
      await Future<void>.delayed(Duration(milliseconds: pollMs));
    }

    // Last health snapshot for diagnosis.
    Map<String, dynamic>? last;
    try {
      final health = await _bridge.health();
      last = health.data?.toJson();
    } catch (_) {}

    return _reply(
      ApiResponse.fail(
        ApiCodes.unavailable,
        'wait_lifecycle timeout after ${timeoutMs}ms '
        '(need health.lifecycleForeground=true)',
        data: {
          'ready': false,
          'elapsedMs': DateTime.now().difference(t0).inMilliseconds,
          'lastHealth': last,
        },
      ),
    );
  }

  FutureOr<CallToolResult> _tap(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final target = (args['targetDesc'] as String? ?? '').trim();
    final wait = args['waitStableMs'] as int?;
    final forceLegacy = args['useLegacyTap'] == true;
    final scrollIntoView = args['scrollIntoView'] != false;
    if (target.isEmpty) {
      return _reply(
        ApiResponse.fail(ApiCodes.badRequest, 'targetDesc is required'),
      );
    }

    final ready = await _ensureSessionForAction(testName: 'tap_flow');
    if (!ready.isOk) return _reply(ready);
    final runner = _runner;
    if (runner == null) return _noSession();

    final looksLikeNav = _looksLikeNavigationTap(target);
    final step = await runner.run(
      action: 'tap',
      actionLabel: 'tap:$target',
      waitStableMs: wait,
      extraSettleMs: looksLikeNav ? config.navigationWaitMs : 0,
      expectNavigation: looksLikeNav,
      extraStepFields: {
        'targetDesc': target,
        'scrollIntoView': scrollIntoView,
      },
      skillAction: forceLegacy
          ? (client) async => {'success': false, 'error': 'forced legacy'}
          : scrollIntoView
              ? (client) => VisibilityAssist.tapEnsuringVisible(
                    client,
                    target: target,
                  )
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
        t.contains('logout') ||
        t.contains('退出') ||
        t.contains('profile') ||
        t.contains('tab_') ||
        t.contains('我的') ||
        t.contains('首页') ||
        t.contains('发现') ||
        t.contains('submit') ||
        t.contains('下一步') ||
        t.contains('确认');
  }

  FutureOr<CallToolResult> _scroll(CallToolRequest request) async {
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

    final ready = await _ensureSessionForAction(testName: 'scroll_flow');
    if (!ready.isOk) return _reply(ready);
    final runner = _runner;
    if (runner == null) return _noSession();

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
    final args = request.arguments ?? const <String, Object?>{};
    final target = (args['targetDesc'] as String? ?? '').trim();
    final text = args['text'] as String? ?? '';
    final wait = args['waitStableMs'] as int?;
    if (target.isEmpty) {
      return _reply(
        ApiResponse.fail(ApiCodes.badRequest, 'targetDesc is required'),
      );
    }

    final ready = await _ensureSessionForAction(testName: 'input_flow');
    if (!ready.isOk) return _reply(ready);
    final runner = _runner;
    if (runner == null) return _noSession();

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

  /// On-demand full-screen capture. Independent of [PerfAgentConfig.captureScreenshots].
  FutureOr<CallToolResult> _screenshot(CallToolRequest request) async {
    final args = request.arguments ?? const <String, Object?>{};
    final maxWidth = (args['maxWidth'] as num?)?.toInt() ?? 720;
    final includeDataUri = args['includeDataUri'] == true;
    final nameArg = (args['name'] as String?)?.trim();

    final client = await _ensureSkillClient();
    if (client == null) {
      return _reply(
        ApiResponse.fail(
          ApiCodes.skillError,
          'flutter_skill not connected — ensure App Bridge is up '
          '(PerfAgent with VM URI)',
        ),
      );
    }

    try {
      await client.ensureConnected();
      var b64 = await client.screenshotBase64(maxWidth: maxWidth);
      if (b64 == null || b64.isEmpty) {
        await _bridge.waitStable(waitStableMs: config.waitStableMs);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        b64 = await client.screenshotBase64(maxWidth: maxWidth);
      }
      if (b64 == null || b64.isEmpty) {
        return _reply(
          ApiResponse.fail(ApiCodes.skillError, 'screenshot empty'),
        );
      }

      String? route;
      try {
        final r = await client.getCurrentRoute();
        route = r['route']?.toString() ??
            r['current']?.toString() ??
            r['name']?.toString();
      } catch (_) {}

      final sessionId = _session?.sessionId ??
          'adhoc_${DateTime.now().millisecondsSinceEpoch}';
      final dir = io.Directory(
        p.join(config.reportsDir, 'screenshots', sessionId),
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final safeName = (nameArg != null && nameArg.isNotEmpty)
          ? nameArg.replaceAll(RegExp(r'[^\w\-]+'), '_')
          : 'shot_${DateTime.now().millisecondsSinceEpoch}';
      final path = p.join(dir.path, '$safeName.png');
      await io.File(path).writeAsBytes(base64Decode(b64));

      return _reply(
        ApiResponse.ok({
          'driver': 'flutter_skill',
          'path': path,
          'route': route,
          'at': DateTime.now().toIso8601String(),
          'sessionId': _session?.sessionId,
          'maxWidth': maxWidth,
          'autoCapture': false,
          'note':
              'On-demand only; tap/input do not auto-screenshot '
              '(captureScreenshots=${config.captureScreenshots}).',
          if (includeDataUri) 'dataUri': 'data:image/png;base64,$b64',
        }),
      );
    } catch (e) {
      return _reply(
        ApiResponse.fail(
          ApiCodes.skillError,
          'screenshot failed: $e',
          data: {'driver': 'flutter_skill'},
        ),
      );
    }
  }

  FutureOr<CallToolResult> _getUiSnapshot(CallToolRequest request) async {
    final client = await _ensureSkillClient();
    if (client != null) {
      try {
        // Prefer interactive() — has bounds for viewport classification.
        Map<String, dynamic> raw;
        try {
          raw = await client.interactive();
        } catch (_) {
          raw = await client.inspectInteractive();
        }
        final enriched = VisibilityAssist.enrichInteractive(raw);
        // Warm tap cache so a following tap can skip a second interactive.
        VisibilityAssist.warmCache(enriched);
        return _reply(
          ApiResponse.ok({
            'driver': 'flutter_skill',
            'data': enriched,
            'note':
                'needsScroll/offScreenTexts: 控件在树里但可能在屏外；'
                '请 tap(scrollIntoView) 或 scroll，勿当成业务隐藏。',
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
            'screenshot (on-demand) + skill_call. '
            'Auto screenshots off by default (captureScreenshots=false). '
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

  /// Attribute Bridge network records onto route steps that missed them.
  Future<void> _backfillStepNetwork(PerfSession session) async {
    if (session.steps.isEmpty) return;
    try {
      final netRes = await _bridge.networkRequests(
        sinceIso: session.startedAt.toIso8601String(),
        limit: 200,
      );
      if (!netRes.isOk || netRes.data == null || netRes.data!.requests.isEmpty) {
        return;
      }
      final all = netRes.data!.requests;
      String netKey(NetworkRequest r) =>
          '${r.startedAt}|${r.method}|${r.url}|${r.statusCode}';
      final assigned = <String>{
        for (final s in session.steps)
          for (final r in s.networkRequests) netKey(r),
      };

      bool routeMatches(String? reqRoute, String? stepRoute) {
        if (reqRoute == null || stepRoute == null) return false;
        final a = reqRoute.trim();
        final b = stepRoute.trim();
        if (a.isEmpty || b.isEmpty) return false;
        if (a == b) return true;
        // Request stamped `/home` can belong to `/home#mine` in the same window.
        if (!a.contains('#') && b.startsWith('$a#')) return true;
        return false;
      }

      final replaced = <StepResult>[];
      for (var i = 0; i < session.steps.length; i++) {
        final step = session.steps[i];
        final end = DateTime.tryParse(step.at ?? '') ?? DateTime.now();
        final begin = i == 0
            ? session.startedAt
            : (DateTime.tryParse(session.steps[i - 1].at ?? '') ??
                session.startedAt);

        final extra = <NetworkRequest>[];
        for (final r in all) {
          if (assigned.contains(netKey(r))) continue;
          final t = DateTime.tryParse(r.startedAt);
          final byTime = t != null &&
              !t.isBefore(begin) &&
              !t.isAfter(end.add(const Duration(seconds: 2)));
          final byRoute = byTime && routeMatches(r.route, step.route);
          if (byRoute || (step.networkRequests.isEmpty && byTime)) {
            extra.add(r);
            assigned.add(netKey(r));
          }
        }
        if (extra.isEmpty) {
          replaced.add(step);
        } else {
          replaced.add(
            step.copyWith(
              networkRequests: [...step.networkRequests, ...extra],
            ),
          );
        }
      }
      session.steps
        ..clear()
        ..addAll(replaced);
    } catch (_) {
      // Non-fatal: report still writes without backfill.
    }
  }

  CallToolResult _noSession() => _reply(
        ApiResponse.fail(
          ApiCodes.noSession,
          'no active session — call start_perf_test first',
        ),
      );

  Future<CallToolResult> _stepReply(StepResult step) async {
    final live = await _afterStep(step);
    final payload = {
      ...step.toJson(includeScreenshotDataUri: false),
      ...live,
    };
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
