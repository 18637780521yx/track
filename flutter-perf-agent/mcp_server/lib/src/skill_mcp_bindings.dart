import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'action_runner.dart';
import 'flutter_skill_client.dart';

/// 将 flutter_skill 全量能力收成少量 MCP 工具（避免 40+ `skill_*`）。
///
/// - [skill_call]：`method` + `args` 调度 [FlutterSkillClient]
/// - [skill_screenshot]：截图单独暴露（载荷大）
///
/// 高频动作仍用 server 上的 `tap` / `input_text` / `scroll`。
/// 手势类 method 在会话中走 [ActionRunner]（Sleuth/RSS diff）。
void registerFlutterSkillTools({
  required void Function(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) handler,
  ) registerTool,
  required Future<FlutterSkillClient?> Function() ensureSkillClient,
  required ActionRunner? Function() runner,
  required CallToolResult Function(ApiResponse<dynamic> response) reply,
}) {
  CallToolResult noSkill() => reply(
        ApiResponse.fail(
          ApiCodes.skillError,
          'flutter_skill not connected — call start_perf_test first '
          '(needs VM URI from PerfBridge)',
        ),
      );

  CallToolResult noSession() => reply(
        ApiResponse.fail(
          ApiCodes.noSession,
          'no active session — call start_perf_test first',
        ),
      );

  CallToolResult bad(String msg) =>
      reply(ApiResponse.fail(ApiCodes.badRequest, msg));

  /// 会改 UI、适合采性能 diff 的 method。
  const mutating = {
    'tap',
    'enterText',
    'scrollTo',
    'swipe',
    'longPress',
    'doubleTap',
    'drag',
    'pressKey',
    'typeText',
    'focus',
    'blur',
    'setCheckbox',
    'hover',
    'tapAt',
    'longPressAt',
    'swipeCoordinates',
    'edgeSwipe',
    'goBack',
  };

  Future<CallToolResult> onDemand(
    Future<Map<String, dynamic>> Function(FlutterSkillClient c) action,
  ) async {
    final client = await ensureSkillClient();
    if (client == null) return noSkill();
    try {
      await client.ensureConnected();
      final data = await action(client);
      return reply(
        ApiResponse.ok({'driver': 'flutter_skill', 'result': data}),
      );
    } catch (e) {
      return reply(
        ApiResponse.fail(
          ApiCodes.skillError,
          e.toString(),
          data: {'driver': 'flutter_skill'},
        ),
      );
    }
  }

  Future<CallToolResult> withPerf({
    required String action,
    required String actionLabel,
    required SkillAction skillAction,
    Map<String, dynamic>? extra,
    int? waitStableMs,
  }) async {
    final r = runner();
    if (r == null) return noSession();
    final step = await r.run(
      action: action,
      actionLabel: actionLabel,
      waitStableMs: waitStableMs,
      extraStepFields: extra,
      skillAction: skillAction,
    );
    final payload = step.toJson(includeScreenshotDataUri: false);
    if (!step.ok) {
      return reply(
        ApiResponse.fail(
          ApiCodes.actionFailed,
          step.actionResult?.error ?? 'action failed',
          data: payload,
        ),
      );
    }
    return reply(ApiResponse.ok(payload));
  }

  Future<Map<String, dynamic>> dispatch(
    FlutterSkillClient c,
    String method,
    Map<String, dynamic> args,
  ) {
    return _dispatchSkill(c, method, args);
  }

  registerTool(
    Tool(
      name: 'skill_call',
      description:
          '调用任意 flutter_skill 方法（全量能力入口）。'
          '常用仍优先 tap/input_text/scroll。'
          'method 示例：longPress, doubleTap, waitForElement, interactive, '
          'getWidgetTree, goBack, getLogs… '
          '手势类在会话中会采 Sleuth/RSS diff。',
      inputSchema: Schema.object(
        properties: {
          'method': Schema.string(
            description: 'FlutterSkillClient 方法名，见工具说明',
          ),
          'args': Schema.object(
            description: '方法参数（JSON object，键与接口命名一致）',
            properties: {},
          ),
          'waitStableMs': Schema.int(
            description: '仅手势类：操作后等待稳定毫秒',
          ),
        },
        required: ['method'],
      ),
    ),
    (req) async {
      final a = req.arguments ?? const <String, Object?>{};
      final method = (a['method'] as String?)?.trim() ?? '';
      if (method.isEmpty) return bad('method required');

      final rawArgs = a['args'];
      final args = <String, dynamic>{};
      if (rawArgs is Map) {
        args.addAll(Map<String, dynamic>.from(rawArgs));
      }

      final wait = (a['waitStableMs'] as num?)?.toInt();

      if (mutating.contains(method)) {
        return withPerf(
          action: 'skill_$method',
          actionLabel: 'skill_call:$method',
          waitStableMs: wait,
          extra: {'method': method, 'args': args},
          skillAction: (c) => dispatch(c, method, args),
        );
      }

      return onDemand((c) async {
        final result = await dispatch(c, method, args);
        return {
          'method': method,
          ...result,
        };
      });
    },
  );

  registerTool(
    Tool(
      name: 'skill_screenshot',
      description: '全屏截图（base64 image）。区域/控件截图用 skill_call '
          'method=screenshotRegion|screenshotElement。',
      inputSchema: Schema.object(
        properties: {
          'quality': Schema.num(description: '0–1，默认 0.65'),
          'maxWidth': Schema.int(description: '默认 720'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final quality = (a['quality'] as num?)?.toDouble() ?? 0.65;
      final maxWidth = (a['maxWidth'] as num?)?.toInt() ?? 720;
      return onDemand(
        (c) => c.screenshot(quality: quality, maxWidth: maxWidth),
      );
    },
  );

  // 列出可用 method，方便模型/人类查阅（轻量）。
  registerTool(
    Tool(
      name: 'skill_list_methods',
      description: '列出 skill_call 可用的 method 名与分类。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => reply(
      ApiResponse.ok({
        'mutating': mutating.toList()..sort(),
        'readonly': _readonlyMethods,
        'note':
            'Prefer tap/input_text/scroll for common flows; '
            'use skill_call for the rest.',
      }),
    ),
  );
}

const _readonlyMethods = [
  'inspectInteractive',
  'interactive',
  'interactiveStructured',
  'getWidgetTree',
  'getWidgetProperties',
  'getTextContent',
  'findByType',
  'waitForElement',
  'waitForGone',
  'getTextValue',
  'getCheckboxState',
  'getSliderValue',
  'screenshot',
  'screenshotRegion',
  'screenshotElement',
  'getCurrentRoute',
  'getNavigationStack',
  'enableIndicators',
  'disableIndicators',
  'getIndicatorStatus',
  'getLogs',
  'getErrors',
  'clearLogs',
  'getPerformance',
  'getFrameStats',
  'getHttpRequests',
  'clearHttpRequests',
];

String? _str(Map<String, dynamic> a, String k) {
  final v = a[k];
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

int _int(Map<String, dynamic> a, String k, [int def = 0]) =>
    (a[k] as num?)?.toInt() ?? def;

double _dbl(Map<String, dynamic> a, String k, [double def = 0]) =>
    (a[k] as num?)?.toDouble() ?? def;

bool? _bool(Map<String, dynamic> a, String k) {
  final v = a[k];
  if (v is bool) return v;
  if (v is String) return v.toLowerCase() == 'true';
  return null;
}

List<String>? _strList(Map<String, dynamic> a, String k) {
  final v = a[k];
  if (v is List) {
    return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }
  if (v is String && v.trim().isNotEmpty) {
    return v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
  return null;
}

/// 将 method 名映射到 [FlutterSkillClient] 调用。
Future<Map<String, dynamic>> _dispatchSkill(
  FlutterSkillClient c,
  String method,
  Map<String, dynamic> args,
) async {
  switch (method) {
    case 'tap':
      return c.tap(
        text: _str(args, 'text'),
        key: _str(args, 'key'),
        ref: _str(args, 'ref'),
      );
    case 'enterText':
      final text = args['text']?.toString() ?? '';
      return c.enterText(
        text: text,
        target: _str(args, 'target'),
        key: _str(args, 'key'),
        ref: _str(args, 'ref'),
      );
    case 'scrollTo':
      return c.scrollTo(key: _str(args, 'key'), text: _str(args, 'text'));
    case 'swipe':
      return c.swipe(
        direction: _str(args, 'direction') ?? 'down',
        distance: _dbl(args, 'distance', 300),
        key: _str(args, 'key'),
      );
    case 'inspectInteractive':
      return c.inspectInteractive();
    case 'screenshot':
      return c.screenshot(
        quality: _dbl(args, 'quality', 0.65),
        maxWidth: _int(args, 'maxWidth', 720),
      );
    case 'interactive':
      return c.interactive(
        includePositions: _bool(args, 'includePositions') ?? true,
      );
    case 'interactiveStructured':
      return c.interactiveStructured();
    case 'getWidgetTree':
      return c.getWidgetTree(maxDepth: _int(args, 'maxDepth', 10));
    case 'getWidgetProperties':
      final key = _str(args, 'key');
      if (key == null) throw ArgumentError('args.key required');
      return c.getWidgetProperties(key);
    case 'getTextContent':
      return c.getTextContent();
    case 'findByType':
      final type = _str(args, 'type');
      if (type == null) throw ArgumentError('args.type required');
      return c.findByType(type);
    case 'longPress':
      return c.longPress(
        key: _str(args, 'key'),
        text: _str(args, 'text'),
        ref: _str(args, 'ref'),
        durationMs: _int(args, 'durationMs', 500),
      );
    case 'doubleTap':
      return c.doubleTap(
        key: _str(args, 'key'),
        text: _str(args, 'text'),
        ref: _str(args, 'ref'),
      );
    case 'drag':
      final from = _str(args, 'fromKey');
      final to = _str(args, 'toKey');
      if (from == null || to == null) {
        throw ArgumentError('args.fromKey and args.toKey required');
      }
      return c.drag(
        fromKey: from,
        toKey: to,
        holdMs: _int(args, 'holdMs'),
      );
    case 'pressKey':
      final key = _str(args, 'key');
      if (key == null) throw ArgumentError('args.key required');
      return c.pressKey(key, modifiers: _strList(args, 'modifiers'));
    case 'typeText':
      return c.typeText(args['text']?.toString() ?? '');
    case 'focus':
      final key = _str(args, 'key');
      if (key == null) throw ArgumentError('args.key required');
      return c.focus(key);
    case 'blur':
      return c.blur(key: _str(args, 'key'));
    case 'setCheckbox':
      final key = _str(args, 'key');
      final checked = _bool(args, 'checked');
      if (key == null || checked == null) {
        throw ArgumentError('args.key and args.checked required');
      }
      return c.setCheckbox(key, checked);
    case 'hover':
      return c.hover(key: _str(args, 'key'), text: _str(args, 'text'));
    case 'tapAt':
      return c.tapAt(x: _dbl(args, 'x'), y: _dbl(args, 'y'));
    case 'longPressAt':
      return c.longPressAt(
        x: _dbl(args, 'x'),
        y: _dbl(args, 'y'),
        durationMs: _int(args, 'durationMs', 500),
      );
    case 'swipeCoordinates':
      return c.swipeCoordinates(
        startX: _dbl(args, 'startX'),
        startY: _dbl(args, 'startY'),
        endX: _dbl(args, 'endX'),
        endY: _dbl(args, 'endY'),
        durationMs: _int(args, 'durationMs', 300),
        holdMs: _int(args, 'holdMs'),
      );
    case 'edgeSwipe':
      final edge = _str(args, 'edge');
      final direction = _str(args, 'direction');
      if (edge == null || direction == null) {
        throw ArgumentError('args.edge and args.direction required');
      }
      return c.edgeSwipe(
        edge: edge,
        direction: direction,
        distance: _dbl(args, 'distance', 200),
      );
    case 'waitForElement':
      return c.waitForElement(
        key: _str(args, 'key'),
        text: _str(args, 'text'),
        timeoutMs: _int(args, 'timeoutMs', 5000),
      );
    case 'waitForGone':
      return c.waitForGone(
        key: _str(args, 'key'),
        text: _str(args, 'text'),
        timeoutMs: _int(args, 'timeoutMs', 5000),
      );
    case 'getTextValue':
      return c.getTextValue(key: _str(args, 'key'));
    case 'getCheckboxState':
      final key = _str(args, 'key');
      if (key == null) throw ArgumentError('args.key required');
      return c.getCheckboxState(key);
    case 'getSliderValue':
      final key = _str(args, 'key');
      if (key == null) throw ArgumentError('args.key required');
      return c.getSliderValue(key);
    case 'screenshotRegion':
      return c.screenshotRegion(
        x: _dbl(args, 'x'),
        y: _dbl(args, 'y'),
        width: _dbl(args, 'width'),
        height: _dbl(args, 'height'),
      );
    case 'screenshotElement':
      final key = _str(args, 'key');
      if (key == null) throw ArgumentError('args.key required');
      return c.screenshotElement(key);
    case 'getCurrentRoute':
      return c.getCurrentRoute();
    case 'goBack':
      return c.goBack();
    case 'getNavigationStack':
      return c.getNavigationStack();
    case 'enableIndicators':
      return c.enableIndicators(style: _str(args, 'style') ?? 'standard');
    case 'disableIndicators':
      return c.disableIndicators();
    case 'getIndicatorStatus':
      return c.getIndicatorStatus();
    case 'getLogs':
      return c.getLogs();
    case 'getErrors':
      return c.getErrors();
    case 'clearLogs':
      return c.clearLogs();
    case 'getPerformance':
      return c.getPerformance();
    case 'getFrameStats':
      return c.getFrameStats();
    case 'getHttpRequests':
      return c.getHttpRequests(
        limit: _int(args, 'limit', 50),
        offset: _int(args, 'offset'),
      );
    case 'clearHttpRequests':
      return c.clearHttpRequests();
    case 'callExtension':
      final ext = _str(args, 'extension') ?? _str(args, 'method');
      if (ext == null) {
        throw ArgumentError('args.extension (or method) required');
      }
      final params = <String, String>{};
      final p = args['params'];
      if (p is Map) {
        p.forEach((k, v) => params[k.toString()] = v.toString());
      }
      return c.callExtension(ext, params);
    default:
      throw ArgumentError(
        'unknown method "$method" — call skill_list_methods',
      );
  }
}
