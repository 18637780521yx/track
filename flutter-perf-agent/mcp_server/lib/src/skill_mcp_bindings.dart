import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_perf_agent_protocol/flutter_perf_agent_protocol.dart';

import 'action_runner.dart';
import 'flutter_skill_client.dart';

/// Registers the full flutter_skill extension surface as MCP tools.
///
/// Gesture / mutation tools use [ActionRunner] when a perf session is active
/// (Sleuth/RSS before→after). Read-only tools call the VM client directly.
/// All replies use `{ code, data, msg }`.
void registerFlutterSkillTools({
  required void Function(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) handler,
  ) registerTool,
  required Future<FlutterSkillVmClient?> Function() ensureSkillClient,
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

  Future<CallToolResult> onDemand(
    Future<Map<String, dynamic>> Function(FlutterSkillVmClient c) action,
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

  String? argStr(Map<String, Object?> a, String k) {
    final v = a[k];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  int? argInt(Map<String, Object?> a, String k) => (a[k] as num?)?.toInt();
  double? argDbl(Map<String, Object?> a, String k) => (a[k] as num?)?.toDouble();
  bool? argBool(Map<String, Object?> a, String k) {
    final v = a[k];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return null;
  }

  // ── Inspect / find ───────────────────────────────────────────────────

  registerTool(
    Tool(
      name: 'skill_interactive',
      description: 'flutter_skill interactive 元素列表（含位置）。',
      inputSchema: Schema.object(
        properties: {
          'includePositions': Schema.bool(description: '是否含坐标，默认 true'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return onDemand(
        (c) => c.interactive(includePositions: argBool(a, 'includePositions') ?? true),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_interactive_structured',
      description: 'flutter_skill 结构化可交互树。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.interactiveStructured()),
  );

  registerTool(
    Tool(
      name: 'skill_get_widget_tree',
      description: '获取 Widget 树。',
      inputSchema: Schema.object(
        properties: {
          'maxDepth': Schema.int(description: '最大深度，默认 10'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return onDemand((c) => c.getWidgetTree(maxDepth: argInt(a, 'maxDepth') ?? 10));
    },
  );

  registerTool(
    Tool(
      name: 'skill_get_widget_properties',
      description: '按 Key 读取 Widget 属性。',
      inputSchema: Schema.object(
        properties: {'key': Schema.string(description: 'Widget Key')},
        required: ['key'],
      ),
    ),
    (req) {
      final key = argStr(req.arguments ?? const {}, 'key');
      if (key == null) return bad('key required');
      return onDemand((c) => c.getWidgetProperties(key));
    },
  );

  registerTool(
    Tool(
      name: 'skill_get_text_content',
      description: '页面可见文本内容。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getTextContent()),
  );

  registerTool(
    Tool(
      name: 'skill_find_by_type',
      description: '按 Widget 类型查找。',
      inputSchema: Schema.object(
        properties: {'type': Schema.string(description: '如 TextField / ElevatedButton')},
        required: ['type'],
      ),
    ),
    (req) {
      final type = argStr(req.arguments ?? const {}, 'type');
      if (type == null) return bad('type required');
      return onDemand((c) => c.findByType(type));
    },
  );

  // ── Gestures (perf-wrapped) ──────────────────────────────────────────

  registerTool(
    Tool(
      name: 'skill_long_press',
      description: '长按；会话中采 Sleuth/RSS diff。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(),
          'text': Schema.string(),
          'ref': Schema.string(),
          'durationMs': Schema.int(description: '默认 500'),
          'waitStableMs': Schema.int(),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      final text = argStr(a, 'text');
      final ref = argStr(a, 'ref');
      if (key == null && text == null && ref == null) {
        return bad('key, text, or ref required');
      }
      return withPerf(
        action: 'long_press',
        actionLabel: 'longPress:${key ?? text ?? ref}',
        waitStableMs: argInt(a, 'waitStableMs'),
        extra: {'key': key, 'text': text, 'ref': ref},
        skillAction: (c) => c.longPress(
          key: key,
          text: text,
          ref: ref,
          durationMs: argInt(a, 'durationMs') ?? 500,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_double_tap',
      description: '双击；会话中采 Sleuth/RSS diff。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(),
          'text': Schema.string(),
          'ref': Schema.string(),
          'waitStableMs': Schema.int(),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      final text = argStr(a, 'text');
      final ref = argStr(a, 'ref');
      if (key == null && text == null && ref == null) {
        return bad('key, text, or ref required');
      }
      return withPerf(
        action: 'double_tap',
        actionLabel: 'doubleTap:${key ?? text ?? ref}',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.doubleTap(key: key, text: text, ref: ref),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_drag',
      description: '从一个 Key 拖到另一个 Key；会话中采性能。',
      inputSchema: Schema.object(
        properties: {
          'fromKey': Schema.string(),
          'toKey': Schema.string(),
          'holdMs': Schema.int(),
          'waitStableMs': Schema.int(),
        },
        required: ['fromKey', 'toKey'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final from = argStr(a, 'fromKey');
      final to = argStr(a, 'toKey');
      if (from == null || to == null) {
        return bad('fromKey and toKey required');
      }
      return withPerf(
        action: 'drag',
        actionLabel: 'drag:$from→$to',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.drag(
          fromKey: from,
          toKey: to,
          holdMs: argInt(a, 'holdMs') ?? 0,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_press_key',
      description: '按物理/逻辑键（如 Enter、Backspace）；可带 modifiers。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(description: '键名，如 Enter'),
          'modifiers': Schema.string(description: '逗号分隔，如 shift,meta'),
          'waitStableMs': Schema.int(),
        },
        required: ['key'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      if (key == null) return bad('key required');
      final mods = argStr(a, 'modifiers')?.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      return withPerf(
        action: 'press_key',
        actionLabel: 'pressKey:$key',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.pressKey(key, modifiers: mods),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_type_text',
      description: '向当前焦点输入文本（不指定控件）。',
      inputSchema: Schema.object(
        properties: {
          'text': Schema.string(),
          'waitStableMs': Schema.int(),
        },
        required: ['text'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final text = a['text'] as String? ?? '';
      return withPerf(
        action: 'type_text',
        actionLabel: 'typeText:len=${text.length}',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.typeText(text),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_focus',
      description: '聚焦到指定 Key 的控件。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(),
          'waitStableMs': Schema.int(),
        },
        required: ['key'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      if (key == null) return bad('key required');
      return withPerf(
        action: 'focus',
        actionLabel: 'focus:$key',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.focus(key),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_blur',
      description: '取消焦点。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(description: '可选'),
          'waitStableMs': Schema.int(),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return withPerf(
        action: 'blur',
        actionLabel: 'blur',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.blur(key: argStr(a, 'key')),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_set_checkbox',
      description: '设置 Checkbox 状态。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(),
          'checked': Schema.bool(),
          'waitStableMs': Schema.int(),
        },
        required: ['key', 'checked'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      final checked = argBool(a, 'checked');
      if (key == null || checked == null) {
        return bad('key and checked required');
      }
      return withPerf(
        action: 'set_checkbox',
        actionLabel: 'setCheckbox:$key=$checked',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.setCheckbox(key, checked),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_hover',
      description: '悬停（桌面/Web）。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(),
          'text': Schema.string(),
          'waitStableMs': Schema.int(),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      final text = argStr(a, 'text');
      if (key == null && text == null) {
        return bad('key or text required');
      }
      return withPerf(
        action: 'hover',
        actionLabel: 'hover:${key ?? text}',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.hover(key: key, text: text),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_tap_at',
      description: '按坐标点击。',
      inputSchema: Schema.object(
        properties: {
          'x': Schema.num(),
          'y': Schema.num(),
          'waitStableMs': Schema.int(),
        },
        required: ['x', 'y'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final x = argDbl(a, 'x');
      final y = argDbl(a, 'y');
      if (x == null || y == null) {
        return bad('x and y required');
      }
      return withPerf(
        action: 'tap_at',
        actionLabel: 'tapAt:$x,$y',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.tapAt(x: x, y: y),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_long_press_at',
      description: '按坐标长按。',
      inputSchema: Schema.object(
        properties: {
          'x': Schema.num(),
          'y': Schema.num(),
          'durationMs': Schema.int(),
          'waitStableMs': Schema.int(),
        },
        required: ['x', 'y'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final x = argDbl(a, 'x');
      final y = argDbl(a, 'y');
      if (x == null || y == null) {
        return bad('x and y required');
      }
      return withPerf(
        action: 'long_press_at',
        actionLabel: 'longPressAt:$x,$y',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.longPressAt(
          x: x,
          y: y,
          durationMs: argInt(a, 'durationMs') ?? 500,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_swipe_coordinates',
      description: '坐标滑动。',
      inputSchema: Schema.object(
        properties: {
          'startX': Schema.num(),
          'startY': Schema.num(),
          'endX': Schema.num(),
          'endY': Schema.num(),
          'durationMs': Schema.int(),
          'holdMs': Schema.int(),
          'waitStableMs': Schema.int(),
        },
        required: ['startX', 'startY', 'endX', 'endY'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final sx = argDbl(a, 'startX');
      final sy = argDbl(a, 'startY');
      final ex = argDbl(a, 'endX');
      final ey = argDbl(a, 'endY');
      if (sx == null || sy == null || ex == null || ey == null) {
        return bad('start/end coordinates required');
      }
      return withPerf(
        action: 'swipe_coordinates',
        actionLabel: 'swipeCoords',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.swipeCoordinates(
          startX: sx,
          startY: sy,
          endX: ex,
          endY: ey,
          durationMs: argInt(a, 'durationMs') ?? 300,
          holdMs: argInt(a, 'holdMs') ?? 0,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_edge_swipe',
      description: '边缘滑动（如 iOS 返回手势）。',
      inputSchema: Schema.object(
        properties: {
          'edge': Schema.string(description: 'left/right/top/bottom'),
          'direction': Schema.string(description: '滑动方向'),
          'distance': Schema.num(),
          'waitStableMs': Schema.int(),
        },
        required: ['edge', 'direction'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final edge = argStr(a, 'edge');
      final direction = argStr(a, 'direction');
      if (edge == null || direction == null) {
        return bad('edge and direction required');
      }
      return withPerf(
        action: 'edge_swipe',
        actionLabel: 'edgeSwipe:$edge:$direction',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.edgeSwipe(
          edge: edge,
          direction: direction,
          distance: argDbl(a, 'distance') ?? 200,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_go_back',
      description: '导航返回；会话中采性能。',
      inputSchema: Schema.object(
        properties: {'waitStableMs': Schema.int()},
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return withPerf(
        action: 'go_back',
        actionLabel: 'goBack',
        waitStableMs: argInt(a, 'waitStableMs'),
        skillAction: (c) => c.goBack(),
      );
    },
  );

  // ── Wait / form state ────────────────────────────────────────────────

  registerTool(
    Tool(
      name: 'skill_wait_for_element',
      description: '等待元素出现。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(),
          'text': Schema.string(),
          'timeoutMs': Schema.int(description: '默认 5000'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      final text = argStr(a, 'text');
      if (key == null && text == null) {
        return bad('key or text required');
      }
      return onDemand(
        (c) => c.waitForElement(
          key: key,
          text: text,
          timeoutMs: argInt(a, 'timeoutMs') ?? 5000,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_wait_for_gone',
      description: '等待元素消失。',
      inputSchema: Schema.object(
        properties: {
          'key': Schema.string(),
          'text': Schema.string(),
          'timeoutMs': Schema.int(description: '默认 5000'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final key = argStr(a, 'key');
      final text = argStr(a, 'text');
      if (key == null && text == null) {
        return bad('key or text required');
      }
      return onDemand(
        (c) => c.waitForGone(
          key: key,
          text: text,
          timeoutMs: argInt(a, 'timeoutMs') ?? 5000,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_get_text_value',
      description: '读取 TextField 当前值。',
      inputSchema: Schema.object(
        properties: {'key': Schema.string(description: '可选；默认当前焦点')},
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return onDemand((c) => c.getTextValue(key: argStr(a, 'key')));
    },
  );

  registerTool(
    Tool(
      name: 'skill_get_checkbox_state',
      description: '读取 Checkbox 状态。',
      inputSchema: Schema.object(
        properties: {'key': Schema.string()},
        required: ['key'],
      ),
    ),
    (req) {
      final key = argStr(req.arguments ?? const {}, 'key');
      if (key == null) return bad('key required');
      return onDemand((c) => c.getCheckboxState(key));
    },
  );

  registerTool(
    Tool(
      name: 'skill_get_slider_value',
      description: '读取 Slider 值。',
      inputSchema: Schema.object(
        properties: {'key': Schema.string()},
        required: ['key'],
      ),
    ),
    (req) {
      final key = argStr(req.arguments ?? const {}, 'key');
      if (key == null) return bad('key required');
      return onDemand((c) => c.getSliderValue(key));
    },
  );

  // ── Screenshot ───────────────────────────────────────────────────────

  registerTool(
    Tool(
      name: 'skill_screenshot',
      description: '全屏截图（返回 base64 image 字段）。',
      inputSchema: Schema.object(
        properties: {
          'quality': Schema.num(description: '0–1，默认 0.65'),
          'maxWidth': Schema.int(description: '默认 720'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return onDemand(
        (c) => c.screenshot(
          quality: argDbl(a, 'quality') ?? 0.65,
          maxWidth: argInt(a, 'maxWidth') ?? 720,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_screenshot_region',
      description: '区域截图。',
      inputSchema: Schema.object(
        properties: {
          'x': Schema.num(),
          'y': Schema.num(),
          'width': Schema.num(),
          'height': Schema.num(),
        },
        required: ['x', 'y', 'width', 'height'],
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      final x = argDbl(a, 'x');
      final y = argDbl(a, 'y');
      final w = argDbl(a, 'width');
      final h = argDbl(a, 'height');
      if (x == null || y == null || w == null || h == null) {
        return bad('x,y,width,height required');
      }
      return onDemand(
        (c) => c.screenshotRegion(x: x, y: y, width: w, height: h),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_screenshot_element',
      description: '按 Key 截取控件。',
      inputSchema: Schema.object(
        properties: {'key': Schema.string()},
        required: ['key'],
      ),
    ),
    (req) {
      final key = argStr(req.arguments ?? const {}, 'key');
      if (key == null) return bad('key required');
      return onDemand((c) => c.screenshotElement(key));
    },
  );

  // ── Navigation ───────────────────────────────────────────────────────

  registerTool(
    Tool(
      name: 'skill_get_current_route',
      description: '当前路由名。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getCurrentRoute()),
  );

  registerTool(
    Tool(
      name: 'skill_get_navigation_stack',
      description: '导航栈。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getNavigationStack()),
  );

  // ── Indicators / logs / skill-side perf ───────────────────────────────

  registerTool(
    Tool(
      name: 'skill_enable_indicators',
      description: '开启 flutter_skill 测试指示器。',
      inputSchema: Schema.object(
        properties: {
          'style': Schema.string(description: '默认 standard'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return onDemand(
        (c) => c.enableIndicators(style: argStr(a, 'style') ?? 'standard'),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_disable_indicators',
      description: '关闭测试指示器。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.disableIndicators()),
  );

  registerTool(
    Tool(
      name: 'skill_get_indicator_status',
      description: '指示器状态。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getIndicatorStatus()),
  );

  registerTool(
    Tool(
      name: 'skill_get_logs',
      description: '应用侧 flutter_skill 日志。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getLogs()),
  );

  registerTool(
    Tool(
      name: 'skill_get_errors',
      description: '应用侧错误列表。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getErrors()),
  );

  registerTool(
    Tool(
      name: 'skill_clear_logs',
      description: '清空 skill 日志缓冲。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.clearLogs()),
  );

  registerTool(
    Tool(
      name: 'skill_get_performance',
      description: 'flutter_skill 内置 performance 快照（非 Sleuth；主指标仍用 get_sleuth_*）。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getPerformance()),
  );

  registerTool(
    Tool(
      name: 'skill_get_frame_stats',
      description: 'flutter_skill 帧统计（辅助；主指标用 Sleuth）。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.getFrameStats()),
  );

  registerTool(
    Tool(
      name: 'skill_get_http_requests',
      description: '应用内手动记录的 HTTP 请求列表。',
      inputSchema: Schema.object(
        properties: {
          'limit': Schema.int(description: '默认 50'),
          'offset': Schema.int(description: '默认 0'),
        },
      ),
    ),
    (req) {
      final a = req.arguments ?? const <String, Object?>{};
      return onDemand(
        (c) => c.getHttpRequests(
          limit: argInt(a, 'limit') ?? 50,
          offset: argInt(a, 'offset') ?? 0,
        ),
      );
    },
  );

  registerTool(
    Tool(
      name: 'skill_clear_http_requests',
      description: '清空应用内 HTTP 请求缓冲。',
      inputSchema: Schema.object(properties: {}),
    ),
    (_) => onDemand((c) => c.clearHttpRequests()),
  );
}
