# Changelog

## 0.9.0 — V3：modal + 门禁 + VM 深挖

- **modal_\***：`TransitionObserver` 识别 Dialog / BottomSheet / `fullscreenDialog`；无名弹层合成 `#modal/N`
- example：我的 Tab「打开泄漏 Dialog」→ 关闭后 WeakRef 仍可达
- **门禁**：`alertOnWeakRef` / `requireMultiRound` / `alertOnSleuthOnly` / `alertOnRssRetain`（默认与 0.8.x 一致；开会话下推）
- **`leakVmDeepProbe`**（默认 false）：MCP 在 WeakRef 泄漏时可选 GC + allocation 注记 `vmDeep` / `evidence+=vm_deep`；**不作唯一 CI 门禁**；release 强制忽略
- **本轮不做**：Hero flight 归因、多会话聚合、动画窗精确帧

## 0.8.7 — 线上采样首刀

- `leakOnlineEnabled` / `leakSampleRate` / `onLeakOnlineEvent`：Release 可按会话采样开启轻量 WeakRef 转场观测
- `LeakOnline`：路由面包屑 + pop 后 `transition_leak` 事件（ring buffer≤64 + 宿主回调）；**无** Bridge / Sleuth 绑定 / 截图 / 手动录制
- `TransitionLeakTracker.track` / `PerfDi` / mixin / `navigatorObservers`：release 仅在 `LeakOnline.active` 时放行
- example：`--dart-define=LEAK_ONLINE=true` 验收（默认关闭）
- **本轮不做**：远程上报、多会话聚合看板、崩溃联动后端

## 0.8.6 — Sleuth 转场绑定

- `SleuthTransitionBinder`：push 时 stamp issue 指纹，pop settle 后差分 allowlist（`heap_growing` / `stream_resource_growth` / `native_memory_growing`）
- 探针 JSON：`sleuthHits` + `evidence`（`weak_ref` / `weak_ref_multi` / `sleuth` / 组合）
- WeakRef 空但 Sleuth hit 仍出 `transition_memory_leak`（MCP + SDK）
- 配置 `transition.sleuthBindEnabled`（默认 true）开会话下推

## 0.8.5 — MCP 转场泄漏配置对齐

- `perf_agent_config.json` → `transition`：`leakTrackEnabled` / `transitionSettleMs` / `leakConfirmRounds` / `leakRssRetainMb`
- `POST /session/start` 下推到 App SDK `TransitionLeakTracker.configure`
- MCP pop 探针使用 `transitionSettleMs`；RSS 辅证阈值用 `leakRssRetainMb`
- 报告 `thresholds` / HTML 展示 settle 与多轮轮数

## 0.8.4 — 报告告警可读性

- HTML 告警展开 `value`：`sleuth_issues` / `sleuth_detector` 列 title·severity；内存告警显示数值与阈值；泄漏摘要 alive/evidence
- `sleuth_issues` 的 `value` 优先结构化（title / severity / category / fixHint）
- 同章多动作：RSS 按**章起点 → 当前 after** 计算 `diff`；`memory_increase` 按 stepId **替换**，与步骤最终 Δ 对齐

## 0.8.3 — GetX/Navigator 自动 hook

- **`PerfDi.put` / `lazyPut` / `putAsync`**：Binding 注册点自动 `TransitionLeakTracker.track`（推荐接入）
- **`PerfAgent.instrumentGetPages`**：注入 `PerfLeakMiddleware`，Bindings 在路由 scope 下执行
- **`PerfAgent.navigatorObservers`**：一键挂 `TransitionObserver`
- **`PerfLeakTrackMixin` / `PerfGetxController`**：`onInit` 自动 track；默认 **不**在 `onClose` untrack（避免漏报外部 retain）；`leakUntrackOnClose` 可开
- example：Bindings 改 `PerfDi`；`ProfilePushController` 仅 `demoRetain`，无手写 track
- **本轮不做**：Sleuth stream 绑定、线上采样、§9

## 0.8.2 — 转场 V2：多轮泄漏确认 + MCP/手动报告统一

- `TransitionLeakTracker`：按路由记录每次 pop 后 `aliveCount`；`leakConfirmRounds`（默认 2）连续非递减且均 >0 → `evidence=weak_ref_multi`
- `PerfAgent.ensureInitialized`：`leakTrackEnabled` / `transitionSettleMs` / `leakConfirmRounds` / `leakRssRetainMb`
- 探针 JSON：`roundIndex`、`aliveCounts`、`multiRoundConfirmed`；HTML 转场段展示多轮摘要
- example：`ProfilePushController` +「打开独立个人页」按钮，故意 `demoRetain` 握持，便于多轮告警验收
- **报告统一**：MCP 全量 upsert 路由章到 App SDK 账本；`stop_perf_test` / live 以 SDK HTML 为准（与手动同款），不再双份 MCP 大报告
- **本轮不做**：GetX/Navigator 全局自动 hook、Sleuth stream 绑定、线上采样、§9

## 0.8.1 — 全量抓包对齐 Sleuth 代理模型

- 关闭 example 的 `enableNetworkMonitoring`，由 PerfAgent 独占 `HttpOverrides`
- 抓包代理按 Sleuth `http_monitor` 重写（订阅永久占有 terminal，避免 drain/asFuture 丢记录），并补齐头/体
- 手动步骤截图后短等网络再落账
- **Host 白名单** `allowedHosts`（`host` / `host:port`）+ `httpsOnly`（本机 http 可例外）

## 0.8.0 — 全会话时间线（模块嵌在时间线内）+ 转场泄漏 V1

- 报告 `schemaVersion=9`；派生 `view.timeline` = **按时间排列的模块段**，每段内嵌 `events`
- HTML：摘要 → 时间线（启动/页面/转场/告警模块段）→ 环境与阈值；不再在时间线外单独堆模块区
- 网络事件落在页面模块内；会话级 FPS/RSS 放在摘要条
- **转场 V1**：`TransitionObserver` → `push`/`pop`/`replace`；`TransitionLeakTracker`（WeakRef，**不强制 GC**）
- pop 后 settle + WeakRef 仍可达 → `transition_memory_leak`；RSS 辅证 → `transition_memory_retain_rss`；窗内卡顿 → `transition_jank`
- Bridge：`/app/route` 带 transitionKind；`POST /transition/leak_probe`
- `PerfLeakTrackMixin` 供 GetxController 登记；example ProfileController 接入
- PRD V1.1：三阶段目标；泄漏主路径不依赖 VM 强制 GC

## 0.7.1 — SDK 报告与 MCP 同款 HTML/JSON

- `buildHtmlReport` / 冷启动分阶段迁入 `protocol`，MCP 与 App SDK 共用
- `SdkReportWriter` 使用与 MCP `ReportWriter` 相同 schema 与 HTML（路由章、时间线、指标卡）
- 手动步骤补 `events[]`，HTML 时间线可展示

## 0.7.0 — 统一操作账本（MCP + 手动）

- **App SDK** 成为报告权威：`SessionJournal` + `SdkReportWriter` + `ManualGestureRecorder`
- 手动点击：指针 hitTest 解析 key/文案/hint，写入同账本；可自动开会话；顶部「结束」出 JSON/HTML
- MCP：`POST /session/step` 镜像步骤；`mcp_guard` 避免合成指针被手动录制；`stop` 返回 `sdkReportPath`
- Bridge：`/session/journal`、`/session/mcp_guard`；`stop` 支持 `writeReport=false` 清理空会话
- PRD：补充「统一操作账本」需求与验收项

## 0.6.7 — example_app 迁入 Sleuth 官方场景页

- 将 sleuth 0.37 example 的 demos / Capture Helpers / custom_detectors 迁入 `example_app/lib/sleuth_demos`
- 「发现」Tab 改为「场景」目录，分组入口打开各 Demo；路由记为 `/demo/<slug>`
- 开启 `enableDeepDebugInstrumentation` + cookbook `customDetectors`（与官方 example 对齐）

## 0.6.6 — 冷启动方案 A 分阶段

- 从 Sleuth startup 推导阶段：Pre-Dart / Framework / 业务启动 / 首帧(vsync·build·raster) / TTFF / TTI
- HTML 冷启动章展示分阶段表 + 占比条；主指标以 TTFF 为准（方案 A）

## 0.6.5 — 路由章内线性事件时间线

- 同路由操作写入 `events[]`：screenshot → action → network → navigate
- 切路由时：源章保留操作/请求/跳转事件；目标章单独落页截图
- HTML 以时间线展示章内事件（含内嵌截图）

## 0.6.4 — 冷启动步骤

- 报告首步固定为 `cold_start`（不与后续同路由操作合并）：Sleuth TTFF/TTI + 首屏截图
- example_app 调用 `Sleuth.init()` / `markInteractive`；Bridge `GET /sleuth/startup`
- 可选 `coldStart.relaunch`：kill + 打开 macOS `.app` 并统计进程就绪耗时
- HTML 冷启动卡片展示 TTFF / TTI / processLaunchMs

## 0.6.3 — 按路由记录步骤

- 报告步骤改为**路由落页**：同路由上的多次操作合并进一个 step；切路由则新开 step（避免登录后立刻进「我的」时漏掉首页截图）
- Bridge `GET /app/route`；example_app 逻辑路由含 Tab（`/home#home|discover|mine`）
- `start_perf_test` 先拍一张起始路由基线；切路由后额外 settle + 截图重试
- 报告 `schemaVersion=7`；HTML 标题展示路由与合并后的操作链

## 0.6.2 — 操作即采样

- UI 工具（`tap` / `input_text` / `scroll` / `skill_call` 手势）无会话时**自动开会话**
- 每步自动 Sleuth/RSS diff，并覆盖写入 `reports/live_<sessionId>.{json,html}`
- `stop_perf_test` 仍写出最终报告；`start_perf_test` 改为可选

## 0.6.1 — MCP skill 工具收拢

- 去掉 40+ `skill_*` 单工具；改为 `skill_call`（method+args）+ `skill_screenshot` + `skill_list_methods`
- 手势类 method 仍走 ActionRunner（Sleuth/RSS）；`FlutterSkillClient` 接口不变

## 0.6.0 — ApiResponse(code/data/msg) + 模型化

- 新增纯 Dart 包 `protocol/`（`flutter_perf_agent_protocol`）：统一 `{ code, data, msg }`
- Bridge HTTP / MCP tool / SleuthFacade / UiActions / BridgeClient / ActionRunner 全部改用模型
- 去掉散落的 `ok` / `error` Map；业务码见 `ApiCodes`（`0`=成功）
- 报告 `schemaVersion=6`；app_sdk / mcp_server → `0.6.0`

## 0.5.1 — flutter_skill 完整能力

- `FlutterSkillVmClient` 覆盖 flutter_skill 全部 VM 扩展（手势 / 检查 / 等待 / 截图 / 导航 / 日志 / HTTP / 指示器等）
- MCP：`skill_*` 工具全量暴露；手势类在会话中走 ActionRunner（Sleuth/RSS diff）
- 保留原有 `tap` / `scroll` / `input_text` / `get_ui_snapshot` 快捷入口
- 未暴露 app 侧写入用扩展 `logHttpRequest`（由被测 App 调用）

## 0.5.0 — Sleuth 完整能力

- Bridge：`/sleuth/snapshot|summary|diagnose|issues|route_health`
- MCP：`get_sleuth_*` 五件套；每步附带 live issues；stop 写入完整快照
- example_app：全量 detector + overlay + 内存预算；建议 `--profile --no-dds`
- 报告 schemaVersion=5（含 sleuthDiagnose / summary / final snapshot）

## 0.4.1 — Sleuth-only 指标

- **性能指标只走 Sleuth + RSS**（PerfBridge snapshot）
- 去掉动作窗 DevTools 采样与相关 MCP 工具（Timeline/CPU/Heap/Inspector/Network/Logs/debug）
- VM WebSocket **仅**用于 flutter_skill UI（点击/输入/滑动/截图）
- 保留 `export/import_session_snapshot`

## 0.4.0 — DevTools VM（程序化，已回退指标路径）

- 曾接入 Timeline / CPU / Heap / HttpProfile / Inspector 等（0.4.1 起指标侧不再使用）
- **本期不做**：App Size、Deep links

## 0.3.0 — Phase3 / V1

- 会话内复用 flutter_skill VM 连接
- 开会话前自动 stop 残留 session
- 登录类 tap 增加导航等待；通用 post-action settle
- 步骤截图写入 reports/screenshots，HTML 嵌入
- 文档：接入、使用、Demo；`scripts/demo.sh`
- 报告 schemaVersion=3

## 0.2.0 — Phase2

- MCP：`input_text` / `scroll`
- JSON + HTML 报告
- 动作重试、debugLog

## 0.1.0 — Phase1

- MCP：`start_perf_test` / `tap` / `stop_perf_test`
- App Bridge + Sleuth 打点
- example_app 登录 Demo
