import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import 'bridge_client.dart';
import 'config.dart';
import 'flutter_skill_client.dart';
import 'perf_diff.dart';
import 'report_writer.dart';

/// Phase1 MCP tools: start_perf_test / stop_perf_test / tap / get_ui_snapshot.
///
/// Architecture:
/// - UI actions → flutter_skill (VM service extensions)
/// - Snapshots / session → App PerfBridge (HTTP)
base class PerfMcpServer extends MCPServer with ToolsSupport {
  PerfMcpServer(
    super.channel, {
    required this.config,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'flutter-perf-agent',
            version: '0.1.1',
          ),
          instructions:
              'Flutter UI via flutter_skill + Sleuth performance capture. '
              '1) Launch example_app (profile, with PerfAgent). '
              '2) start_perf_test. 3) tap. 4) stop_perf_test for JSON report.',
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
  String? _vmWsUri;
  int _stepCounter = 0;

  final _startTool = Tool(
    name: 'start_perf_test',
    description:
        '启动性能测试会话：连接 App PerfBridge，记录 VM URI（供 flutter_skill），读取基线快照。',
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
        '用 flutter_skill 点击控件（text/key），操作前后经 Bridge 采集 Sleuth/RSS 快照并算 diff。'
        '若 flutter_skill 不可用则回退到 Bridge legacy tap。',
    inputSchema: Schema.object(
      properties: {
        'targetDesc': Schema.string(
          description: '控件文本或 Key，例如「登录」或 login_button',
        ),
        'waitStableMs': Schema.int(description: '操作后等待稳定毫秒'),
        'useLegacyTap': Schema.bool(
          description: '强制使用 Bridge legacy 语义点击（默认 false）',
        ),
      },
      required: ['targetDesc'],
    ),
  );

  final _uiTool = Tool(
    name: 'get_ui_snapshot',
    description: '获取当前可交互控件（优先 flutter_skill inspect，失败则 Bridge /ui）。',
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
    if (started['ok'] != true) {
      return _err(started);
    }

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

    return _ok({
      'sessionId': _session!.sessionId,
      'testName': testName,
      'mode': health['mode'],
      'baseline': started['baseline'],
      'bridge': config.bridgeBaseUrl,
      'vmServiceUri': _vmWsUri,
      'uiDriver': 'flutter_skill',
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
    _vmWsUri = null;
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
    final target = (args['targetDesc'] as String? ?? '').trim();
    final wait = args['waitStableMs'] as int? ?? config.waitStableMs;
    final forceLegacy = args['useLegacyTap'] == true;
    if (target.isEmpty) {
      return _err({'ok': false, 'error': 'targetDesc is required'});
    }

    _stepCounter += 1;
    final stepId = 'step_$_stepCounter';
    final t0 = DateTime.now();

    // 1) before snapshot
    final beforeRes = await _bridge.snapshot();
    if (beforeRes['ok'] != true) return _err(beforeRes);
    final before =
        (beforeRes['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};

    // 2) UI action via flutter_skill (or legacy fallback)
    Map<String, dynamic> actionResult;
    String driver;
    if (!forceLegacy && _vmWsUri != null) {
      driver = 'flutter_skill';
      actionResult = await _tapWithFlutterSkill(target);
      if (!_actionOk(actionResult)) {
        // fallback
        driver = 'legacy_fallback';
        final legacy = await _bridge.tapLegacy(
          targetDesc: target,
          waitStableMs: wait,
        );
        actionResult = {
          'success': legacy['ok'] == true,
          'flutterSkill': actionResult,
          'legacy': legacy['action'],
        };
      } else {
        await _bridge.waitStable(waitStableMs: wait);
      }
    } else {
      driver = 'legacy';
      final legacy = await _bridge.tapLegacy(
        targetDesc: target,
        waitStableMs: wait,
      );
      actionResult = {
        'success': legacy['ok'] == true,
        'legacy': legacy['action'],
        'diffFromBridge': legacy['diff'],
      };
      if (legacy['ok'] == true && legacy['diff'] is Map) {
        // Bridge legacy already includes diff; still recompute for consistency.
      }
    }

    // 3) after snapshot
    final afterRes = await _bridge.snapshot();
    if (afterRes['ok'] != true) return _err(afterRes);
    final after =
        (afterRes['snapshot'] as Map?)?.cast<String, dynamic>() ?? {};

    final diff = computePerfDiff(
      before: before,
      after: after,
      durationMs: DateTime.now().difference(t0).inMilliseconds,
    );

    final ok = _actionOk(actionResult);
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
      'driver': driver,
      'ok': ok,
      'actionResult': actionResult,
      'diff': diff,
      'alerts': alerts,
      'at': DateTime.now().toIso8601String(),
    };
    session.addStep(step);
    return _ok(step);
  }

  Future<Map<String, dynamic>> _tapWithFlutterSkill(String target) async {
    final client = FlutterSkillVmClient(_vmWsUri!);
    try {
      await client.connect();
      // Natural language / visible text first; Key id as secondary.
      return await client.tap(text: target, key: target);
    } catch (e) {
      return {
        'success': false,
        'error': 'flutter_skill tap failed: $e',
        'vmServiceUri': _vmWsUri,
      };
    } finally {
      await client.disconnect();
    }
  }

  FutureOr<CallToolResult> _getUiSnapshot(CallToolRequest request) async {
    if (_vmWsUri != null) {
      final client = FlutterSkillVmClient(_vmWsUri!);
      try {
        await client.connect();
        final inspected = await client.inspectInteractive();
        return _ok({
          'ok': true,
          'driver': 'flutter_skill',
          'data': inspected,
        });
      } catch (e) {
        // fall through to bridge
        final ui = await _bridge.ui();
        return _ok({
          ...ui,
          'driver': 'bridge_fallback',
          'flutterSkillError': e.toString(),
        });
      } finally {
        await client.disconnect();
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
      'reportsDir': config.reportsDir,
      'uiDriver': 'flutter_skill',
      'thresholds': {
        'maxFrameCostMs': config.maxFrameCostMs,
        'memoryIncreaseWarningMB': config.memoryIncreaseWarningMB,
        'slowRequestMs': config.slowRequestMs,
      },
    });
  }

  bool _actionOk(Map<String, dynamic> result) {
    if (result['success'] == true || result['ok'] == true) return true;
    // flutter_skill sometimes returns success nested
    final nested = result['result'];
    if (nested is Map && (nested['success'] == true || nested['ok'] == true)) {
      return true;
    }
    return false;
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
