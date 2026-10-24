# 性能事件说明

本文说明 Flutter-Perf-Agent **会话报告时间线里会出现哪些事件**，以及 **哪些性能问题会被记成告警事件**。  
权威账本在 App SDK（`SessionJournal`）；HTML 主视图渲染派生后的 `view.timeline`（见 [Flutter-Perf-Agent.md](Flutter-Perf-Agent.md) §4.3.2）。

**原则：告警类型只表示「出了什么问题」，不编码「在转场还是在操作窗」。**  
卡顿就是 `jank` / `slow_frame`，泄漏就是 `memory_leak`；它们出现在 **页面段** 还是 **转场段**，由触发 step（是否伴随 `navigate`）决定，见下方「挂载位置」。

性能问题与操作同源：多数在点击、输入、滚动、跳转或伴随网络之后出现，以 **`type=alert` 事件**挂在对应段内，并尽量 **紧跟触发该步的操作 / 网络 / navigate**（**无**独立「性能报告」模块卡；设计稿见 [design/report-timeline-v4-inline-alerts.jpg](design/report-timeline-v4-inline-alerts.jpg)）。

---

## 1. 时间线事件类型

| `type` | 含义 | 常见 `label` | 主要出现在 |
|--------|------|--------------|------------|
| `cold_start` | 冷启动 | 冷启动 | 生命周期段 |
| `lifecycle` | 前后台等 | App 进入后台 / 前台 | 生命周期段 |
| `action` | UI 操作 | `tap:…` / `input:…` / `scroll:…` | 页面段 |
| `network` | HTTP 请求 | `GET/POST …` | 页面段（操作窗口内） |
| `navigate` | 路由变化 | `from → to`（细节在段字段） | 转场段 |
| `alert` | 性能 / 质量问题 | 见下文告警类型 | 页面段或转场段（跟触发 step） |
| `screenshot` | 截图 | — | **非路径主叙事**（兼容字段，可忽略） |

公共字段（最小集）：`type`, `label`, `at`, `ok`, `source`（`mcp` \| `manual`，操作类）, `route`, `stepId`, `detail?`。

### 1.1 操作类 `action`

| 来源 | 能记什么 | 备注 |
|------|----------|------|
| MCP（`tap` / `scroll` / `input_text` / 手势类 `skill_call`） | 点击、滚动、输入 | 写入账本时 `source=mcp`；期间 `mcp_guard` 抑制人手重复记账 |
| 人手指针 | 点击、拖动判定的滚动 | `ManualGestureRecorder`；`source=manual` |
| 人手键盘 / IME | **当前不记** | 报告格式已支持 `input:`，人手打字尚未接入 |

### 1.2 网络 `network`

- 来源：App 内 `HttpOverrides` 环缓，挂在操作后的 settle 窗口。
- 字段侧重：method、url、status、耗时、可选 body 摘要。
- **不覆盖**：WebSocket、gRPC、绕过 Overrides 的原生客户端等。

### 1.3 转场 `navigate`

- 路由变化写入转场段：`from` / `to` / `transitionKind`（如 `route_change`、`tab_change`、`modal_*`）。
- 同一步上检出的卡顿 / 泄漏等 `alert` 落在 **同一转场段**（紧跟 `navigate`）。

---

## 2. 本产品直接产出的告警（`detail.alertType`）

原始列表在报告 JSON 的 `alerts[]`；派生进时间线时为 `type=alert`，`detail.type` / `detail.alertType` 为规范名。`ok` 一般为 `false`。

> **0.9.9+**：Sleuth 性能类告警（下表 `jank`～结构扫描等）受总开关 `sleuthPerfEnabled` 控制，**默认关闭**。RSS `memory_increase` 另受 `memoryIncreaseAlertEnabled` 控制（**默认关闭**）。`crash` / 网络 / WeakRef `memory_leak` 不受影响。

| `alertType` | 检测什么 | 默认门槛（可配置） | 挂载位置 |
|-------------|----------|-------------------|----------|
| `jank` | 单帧超预算（Sleuth capture + FrameVerdict） | 帧预算（默认 ~16ms） | **实时**（App SDK `FrameJankLatch`，MCP/手动共用）；按 `at` 挂页面/转场 |
| `slow_frame` | 单帧严重超预算（≥ 预算×2） | 同上 | 同上 |
| `gc_pressure` | GC 过于频繁 | Sleuth MemoryPressure（开发 VM） | **实时**（0.9.6 `SleuthIssueLatch`）；页面/转场 |
| `heap_growing` | Dart 堆持续上涨 | 同上 | 同上；转场 `sleuthHits` 仍可作泄漏辅证 |
| `heap_near_capacity` | 堆/预算逼近上限 | 需 `memoryBudgetBytes` | 同上 |
| `native_memory_growing` | 原生/外部内存斜率异常 | 同上 | 同上 |
| `shader_compilation` | 着色器/管线编译卡顿 | ShaderJank；**Impeller Metal 无效** | **实时**（0.9.7 D0s） |
| `heavy_compute` | UI 线程长时间同步计算 | HeavyCompute；VM | **实时**；兼作 event-loop 邻近信号 |
| `platform_channel_traffic` | PlatformChannel 过频/过重 | PlatformChannel；VM | **实时** |
| `stream_resource_growth` | StreamSubscription 等资源增长（含忘 cancel） | StreamResource | **实时** |
| `rebuild_activity` | Widget 频繁重建 | RebuildDetector | **实时** |
| `excessive_repaint` | RenderObject 反复重绘（运行时） | RepaintDetector | **实时** |
| `missing_repaint_boundary` 等 | Widget **树静态扫描**命中 | structural detectors | **实时**（0.9.7 D0s#9）；stableId 去重 |
| `layout_bottleneck` / `non_lazy_list` / `setstate_scope` / … | 同上 | 见 APM-PRD D0s 结构表 | **实时** |
| `memory_increase` | 单步 **RSS** 上涨过大 | `memoryIncreaseWarningMB` = **5** MB | **仅 MCP** 操作窗 diff → **页面**；≠ 堆增长；手动路径当前不发 |
| `memory_leak` | 登记对象仍可达 / 多轮仍存活 | WeakRef 等主判定（不依赖强制 GC） | **转场**（pop 后探针；MCP + 手动共用） |
| `memory_retain_rss` | 无存活登记对象但 RSS 滞留 | `leakRssRetainMb` = **5** MB；**辅证**，RSS 不单独定罪 | **转场** |
| `sleuth_issues` / `sleuth_detector` | （遗留大包） | — | **0.9.9+ 不再新写**；HTML/`view` 会拆成一等 `alertType` 事件（`sustained_jank` / `gc_pressure` / …） |
| `slow_cold_start` | 冷启动偏慢（如 TTFF） | `ttffWarningMs` | **生命周期**（启动；MCP 路径） |
| `crash` | FlutterError / Zone / PlatformDispatcher 未捕获 | 会话进行中即记 | **页面**（D1 `CrashCapture`）；`value.kind`=`flutter_error`\|`uncaught`\|`zone`；含截断 stack |

旧报告若仍写 `transition_jank` / `transition_memory_leak` / `transition_memory_retain_rss`，派生层会规范成上表名称（`detail.legacyType` 保留原名）。

### 2.1 卡顿：现状 vs 目标

| | **现状（0.9.5 D0 首刀）** | **仍改进** |
|--|--------------------------|------------|
| 怎么发现 | Sleuth `capturedFrames`（最差 jank 缓冲）→ **立刻** `alert` | 非缓冲内的轻红帧可能漏；理想 push 订阅需 Sleuth 公开 `verdictNotifier` |
| 时间线 | 按帧真实 `at` 多条；标签如 `jank:32ms@build` | 可选轻合并 |
| 和操作关系 | 挂当前页面/转场章；带 `stepId` | — |
| **诱因（有 VM）** | **已进报告**：`suspectedPhase` / `reason` / `relatedIssues` / `topFunctions`（异步升级）/ `vmMode` | — |
| **诱因（无 VM）** | `uiMs`/`rasterMs` + `vmMode=basic` | — |
| 旧窗口 diff | `jankDelta`/`p90` **仅留 step.diff 摘要**，不再发 AlertItem | — |

产品原则：开发/测试能连 VM 时 **能用就用满**。详见 [APM-PRD.md](APM-PRD.md) §6.1 D0；**下一刀**转 D0m / D0s。

### 2.2 内存压力：现状 vs 目标（D0m）

| | **现状（0.9.6 D0m）** | **仍改进** |
|--|----------------------|------------|
| `gc_pressure` / `heap_growing` / `heap_near_capacity` / `native_memory_growing` | Sleuth issue 增量 → **立刻** `alert`（stableId 去重 / severity 升级再发） | 轮询非 push；数值字段依赖 issue raw |
| 转场 `sleuthHits` | 保留作泄漏辅证 | **不替代**实时事件 |
| `memory_increase` | RSS 步差（MCP） | 与堆事件并存、语义分开 |

### 2.3 其它 Sleuth 能力 → 事件（D0s）

**0.9.7**：经 `SleuthIssueLatch` **已一等接入**（与 D0m 同管道）。`jank_detected` 排除（避免与 D0 帧 latch 重复）。

| 能力 | 事件名 | 状态 |
|------|--------|------|
| Shader Jank | `shader_compilation` | 已接入（Metal Impeller 静默） |
| Heavy Compute | `heavy_compute` | 已接入 |
| PlatformChannel 高频 | `platform_channel_traffic` | 已接入 |
| GC / 堆涨 / 逼近上限 | 见 §2 / D0m | 0.9.6 |
| StreamSubscription 泄漏 | `stream_resource_growth` | 已接入 |
| Event Loop Stall | `heavy_compute` + `sustained_jank` | 映射覆盖；无一等名 |
| Widget 重建 / Excessive Repaint | `rebuild_activity` / `excessive_repaint` | 已接入 |
| Widget 树静态扫描 | `missing_repaint_boundary` / `layout_bottleneck` / `non_lazy_list` / `setstate_scope` / … | **已接入** |
| 网络升一等 | `slow_request` / `large_response` / … | 已接入（与 `network` 事件并存） |

详见 [APM-PRD.md](APM-PRD.md) §6.1 D0s。

---

## 3. 经 Sleuth 透传、仍可后续升一等的问题

| 类别 | 例子 | 备注 |
|------|------|------|
| 网络 | `slow_request` / `request_frequency` / `large_response` | 建议升一等（APM 开放问题） |
| 结构 | `missing_repaint_boundary` / layout_bottleneck 等 | 可随 D0s 或二期 |
| 其它 | 见 Sleuth encyclopedia / `sleuthDiagnose` | |

接入与开关见 [flutter-perf-agent/docs/INTEGRATION.md](../flutter-perf-agent/docs/INTEGRATION.md)、[USAGE.md](../flutter-perf-agent/docs/USAGE.md)。

---

## 4. 明确未采集或弱覆盖

| 项 | 状态 |
|----|------|
| 人手键盘输入 | 未记为 `input:` |
| 长按 / 双指等复杂手势 | 非目标 |
| 崩溃 / 未捕获异常流水 | **已接入** `crash`（0.9.8）；致命退出前尽量写 live 报告；完整线上上报见 APM O7 |
| Platform Channel 耗时 | **无一等事件进账本**；Sleuth 有 `platform_channel_traffic` detector，待 D0s latch |
| WebSocket / 非 HttpOverrides 流量 | 不采集 |
| 连续 FPS / RSS 曲线 | 仅有步骤窗口差值与会话摘要峰值 |
| 业务埋点 / 自定义分析事件 | 不进本报告账本 |
| 完整堆 Diff 图形化 | 非目标；泄漏走登记对象 + 可选 VM 深挖 |

---

## 5. 在报告里怎么读

1. 摘要条：`alertCount` 等会话级数字。  
2. 时间线：按 **生命周期 → 页面 → 转场 → 页面…** 读路径；在某次 `tap:` / `network` / `navigate` 下方看紧跟的 `alert`（例如转场里的 `memory_leak`、`jank`）。  
3. 页脚：阈值与 Sleuth diagnose。  
4. JSON：`alerts[]` 为告警权威列表；`view.timeline[].events` 为展示用内联结果。

阈值字段示例：`maxFrameCostMs`、`memoryIncreaseWarningMB`、`slowRequestMs`、`ttffWarningMs`、`leakRssRetainMb`、`leakConfirmRounds`（详见报告「环境与阈值」或 MCP `get_perf_threshold_config`）。

---

## 相关文档

- 产品 PRD / 报告信息架构：[Flutter-Perf-Agent.md](Flutter-Perf-Agent.md) §4.2、§4.3.2、§4.3.3  
- 使用教程：[flutter-perf-agent/docs/USAGE.md](../flutter-perf-agent/docs/USAGE.md)  
- 接入：[flutter-perf-agent/docs/INTEGRATION.md](../flutter-perf-agent/docs/INTEGRATION.md)  
