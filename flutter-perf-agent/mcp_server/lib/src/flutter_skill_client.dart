/// flutter_skill UI 自动化抽象：通过 App 内注册的
/// `ext.flutter.flutter_skill.*` 扩展驱动控件。
///
/// MCP / ActionRunner 只依赖本接口；VM 实现见
/// `flutter_skill_vm_client.dart` 中的 [FlutterSkillVmClient]。
///
/// 方法返回值一般为 flutter_skill 原始 `Map`（含 `success` / `error` 等），
/// 成功判定可用 [FlutterSkillVmClient.isOk]。
abstract class FlutterSkillClient {
  /// 规范化后的 WebSocket URI（`ws://…/ws`）。
  String get wsUri;

  /// 当前是否已绑定 isolate。
  bool get isConnected;

  /// 建立 VM Service 连接并选中 main isolate。
  Future<void> connect();

  /// 若连接已断（热重启 / isolate 回收），则自动重连。
  Future<void> ensureConnected();

  /// 释放 VM Service 连接。
  Future<void> disconnect();

  /// 直接调用任意 service extension（调试 / 扩展用）。
  Future<Map<String, dynamic>> callExtension(
    String method, [
    Map<String, String>? params,
  ]);

  // ── 基础手势 / 输入 ──────────────────────────────────────────────────

  /// 点击：按 [text] / [key] / [ref] 依次尝试匹配。
  Future<Map<String, dynamic>> tap({String? text, String? key, String? ref});

  /// 向目标输入框写入 [text]（优先 Key，失败则 tap 聚焦后再输）。
  Future<Map<String, dynamic>> enterText({
    required String text,
    String? target,
    String? key,
    String? ref,
  });

  /// 滚动直到 [key] 或 [text] 可见。
  Future<Map<String, dynamic>> scrollTo({String? key, String? text});

  /// 方向滑动（`up` / `down` / `left` / `right`）。
  Future<Map<String, dynamic>> swipe({
    required String direction,
    double distance = 300,
    String? key,
  });

  /// 可交互控件巡检（legacy inspect）。
  Future<Map<String, dynamic>> inspectInteractive();

  /// 全屏截图，返回 PNG/JPEG base64；失败为 `null`。
  Future<String?> screenshotBase64({int maxWidth = 720});

  /// 全屏截图原始扩展结果（含 `image` 字段）。
  Future<Map<String, dynamic>> screenshot({
    double quality = 0.65,
    int maxWidth = 720,
  });

  // ── 检查 / 查找 ──────────────────────────────────────────────────────

  /// 可交互元素列表（可选坐标）。
  Future<Map<String, dynamic>> interactive({bool includePositions = true});

  /// 结构化可交互树。
  Future<Map<String, dynamic>> interactiveStructured();

  /// Widget 树（深度上限 [maxDepth]）。
  Future<Map<String, dynamic>> getWidgetTree({int maxDepth = 10});

  /// 按 Key 读取 Widget 属性。
  Future<Map<String, dynamic>> getWidgetProperties(String key);

  /// 页面可见文本。
  Future<Map<String, dynamic>> getTextContent();

  /// 按类型名查找 Widget（如 `TextField`）。
  Future<Map<String, dynamic>> findByType(String type);

  // ── 进阶手势 ─────────────────────────────────────────────────────────

  /// 长按。
  Future<Map<String, dynamic>> longPress({
    String? key,
    String? text,
    String? ref,
    int durationMs = 500,
  });

  /// 双击。
  Future<Map<String, dynamic>> doubleTap({
    String? key,
    String? text,
    String? ref,
  });

  /// 从 [fromKey] 拖到 [toKey]。
  Future<Map<String, dynamic>> drag({
    required String fromKey,
    required String toKey,
    int holdMs = 0,
  });

  /// 按物理/逻辑键（可带 modifiers）。
  Future<Map<String, dynamic>> pressKey(String key, {List<String>? modifiers});

  /// 向当前焦点输入文本。
  Future<Map<String, dynamic>> typeText(String text);

  /// 聚焦到指定 Key。
  Future<Map<String, dynamic>> focus(String key);

  /// 取消焦点。
  Future<Map<String, dynamic>> blur({String? key});

  /// 设置 Checkbox。
  Future<Map<String, dynamic>> setCheckbox(String key, bool checked);

  /// 悬停（桌面 / Web）。
  Future<Map<String, dynamic>> hover({String? key, String? text});

  /// 坐标点击。
  Future<Map<String, dynamic>> tapAt({required double x, required double y});

  /// 坐标长按。
  Future<Map<String, dynamic>> longPressAt({
    required double x,
    required double y,
    int durationMs = 500,
  });

  /// 坐标滑动。
  Future<Map<String, dynamic>> swipeCoordinates({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    int durationMs = 300,
    int holdMs = 0,
  });

  /// 边缘滑动（如系统返回手势）。
  Future<Map<String, dynamic>> edgeSwipe({
    required String edge,
    required String direction,
    double distance = 200,
  });

  // ── 等待 / 表单状态 ──────────────────────────────────────────────────

  /// 等待元素出现。
  Future<Map<String, dynamic>> waitForElement({
    String? key,
    String? text,
    int timeoutMs = 5000,
  });

  /// 等待元素消失。
  Future<Map<String, dynamic>> waitForGone({
    String? key,
    String? text,
    int timeoutMs = 5000,
  });

  /// 读取 TextField 当前值。
  Future<Map<String, dynamic>> getTextValue({String? key});

  /// 读取 Checkbox 状态。
  Future<Map<String, dynamic>> getCheckboxState(String key);

  /// 读取 Slider 值。
  Future<Map<String, dynamic>> getSliderValue(String key);

  // ── 截图 / 导航 ──────────────────────────────────────────────────────

  /// 区域截图。
  Future<Map<String, dynamic>> screenshotRegion({
    required double x,
    required double y,
    required double width,
    required double height,
  });

  /// 按 Key 截取控件。
  Future<Map<String, dynamic>> screenshotElement(String key);

  /// 当前路由名。
  Future<Map<String, dynamic>> getCurrentRoute();

  /// 导航返回。
  Future<Map<String, dynamic>> goBack();

  /// 导航栈。
  Future<Map<String, dynamic>> getNavigationStack();

  // ── 指示器 / 日志 / 辅助指标 ─────────────────────────────────────────

  /// 开启测试指示器。
  Future<Map<String, dynamic>> enableIndicators({String style = 'standard'});

  /// 关闭测试指示器。
  Future<Map<String, dynamic>> disableIndicators();

  /// 指示器状态。
  Future<Map<String, dynamic>> getIndicatorStatus();

  /// App 侧 flutter_skill 日志缓冲。
  Future<Map<String, dynamic>> getLogs();

  /// App 侧错误列表。
  Future<Map<String, dynamic>> getErrors();

  /// 清空日志缓冲。
  Future<Map<String, dynamic>> clearLogs();

  /// flutter_skill 内置 performance（主指标仍用 Sleuth）。
  Future<Map<String, dynamic>> getPerformance();

  /// flutter_skill 帧统计（辅助）。
  Future<Map<String, dynamic>> getFrameStats();

  /// App 内手动记录的 HTTP 请求。
  Future<Map<String, dynamic>> getHttpRequests({int limit = 50, int offset = 0});

  /// 清空 HTTP 请求缓冲。
  Future<Map<String, dynamic>> clearHttpRequests();
}
