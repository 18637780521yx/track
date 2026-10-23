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

| `alertType` | 检测什么 | 默认门槛（可配置） | 挂载位置 |
|-------------|----------|-------------------|----------|
| `jank` | 单帧超预算（红帧） | `maxFrameCostMs` = **16** ms | 按事件 `at` 落入当时 **页面/转场**；靠近最近操作 |
| `slow_frame` | 单帧严重超预算或窗口摘要 P90（见下） | 可配倍数或仍用 `maxFrameCostMs` | 同上 / 步摘要 |
| `gc_pressure` | GC 过于频繁 | Sleuth MemoryPressure（开发 VM） | **目标：触发即发**（D0m）；现状未一等接入 |
| `heap_growing` | Dart 堆持续上涨 | 同上 | **目标：触发即发**（D0m）；现状多在转场 `sleuthHits` |
| `heap_near_capacity` | 堆/预算逼近上限 | 需 `memoryBudgetBytes` | **目标：触发即发**（D0m） |
| `native_memory_growing` | 原生/外部内存斜率异常 | 同上 | 可选同批 D0m |
| `shader_compilation` | 着色器/管线编译卡顿 | ShaderJank；**Impeller Metal 无效** | **目标：触发即发**（D0s） |
| `heavy_compute` | UI 线程长时间同步计算 | HeavyCompute；VM | **目标：触发即发**（D0s）；兼作 event-loop 阻塞邻近信号 |
| `platform_channel_traffic` | PlatformChannel 过频/过重 | PlatformChannel；VM | **目标：触发即发**（D0s） |
| `stream_resource_growth` | StreamSubscription 等资源增长（含忘 cancel） | StreamResource | **目标：触发即发**（D0s） |
| `rebuild_activity` | Widget 频繁重建 | RebuildDetector | **目标：触发即发**（D0s） |
| `excessive_repaint` | RenderObject 反复重绘（运行时） | RepaintDetector | **目标：触发即发**（D0s） |
| `missing_repaint_boundary` 等 | Widget **树静态扫描**命中 | structural detectors | **目标：扫描命中即发**（D0s#9）；按 stableId 去重 |
| `layout_bottleneck` / `non_lazy_list` / `setstate_scope` / … | 同上 | 见 APM-PRD D0s 结构表 | 同上 |
| `memory_increase` | 单步 **RSS** 上涨过大 | `memoryIncreaseWarningMB` = **5** MB | 多为 **页面**（操作窗 diff）；≠ 堆增长 |
| `memory_leak` | 登记对象仍可达 / 多轮仍存活 | WeakRef 等主判定（不依赖强制 GC） | 多为 **转场**（pop 后探针） |
| `memory_retain_rss` | 无存活登记对象但 RSS 滞留 | `leakRssRetainMb` = **5** MB；**辅证**，RSS 不单独定罪 | 多为 **转场** |
| `sleuth_issues` | 本步新增 Sleuth issue 条数 | 有增量即报 | 笼统汇总；逐步被上表一等类型替代 |
| `sleuth_detector` | 当前存在 warning+ 级 Sleuth issue | 有即汇总 | 同上 |
| `slow_cold_start` | 冷启动偏慢（如 TTFF） | `ttffWarningMs` | **生命周期**（启动） |

旧报告若仍写 `transition_jank` / `transition_memory_leak` / `transition_memory_retain_rss`，派生层会规范成上表名称（`detail.legacyType` 保留原名）。

### 2.1 卡顿：现状 vs 目标

| | **现状（不准确，将降级）** | **目标（D0 / 下一刀）** |
|--|---------------------------|-------------------------|
| 怎么发现 | 操作前后读 Sleuth **累计** `jankCount` / `p90`，做差 | 本帧超预算 → **立刻发事件** |
| 时间线 | 一条「本步新增 Jank N 次」 | 按真实 `at` 多条（或轻合并） |
| 和操作关系 | 窗口内帧都算到该操作 | 按时间靠近操作；可带 `stepId` |
| **诱因（有 VM）** | **未进报告** | **必须尽量展示**：`suspectedPhase`（build/layout/paint/raster）、Verdict `reason`、`relatedIssues`、有则 `topFunctions`（Sleuth `FrameVerdict`） |
| **诱因（无 VM / 线上）** | — | 仅 ui/raster 耗时等基础字段；不假装有阶段拆分 |

产品原则：开发/测试能连 VM 时 **能用就用满**；UI bound 时报告里要能读出「卡在哪段、关联哪些 issue」，而不是只有计数。详见 [APM-PRD.md](APM-PRD.md) §1.2、§6.1 D0、**M0.5**。

### 2.2 内存压力：现状 vs 目标（D0m）

| | **现状** | **目标（D0m）** |
|--|----------|-----------------|
| `gc_pressure` / `heap_growing` / `heap_near_capacity` | Sleuth 能检出；报告侧几乎无独立事件 | Detector 触发 → **立刻** `alert` 进时间线 |
| 转场 `sleuthHits` | 仅 pop 窗偶然带上 heap_growing 等 | 保留作泄漏辅证，**不替代**实时事件 |
| `memory_increase` | RSS 步差 | 保留；与堆事件并存、语义分开 |

### 2.3 其它 Sleuth 能力 → 事件（D0s）

下列 **Sleuth 均具备**（除「独立 Event Loop Stall」）；**报告侧现状大多未一等接入**，目标与卡顿/内存压力相同：latch → 时间线。

| 你列的能力 | 有无 | 事件名 | 进时间线（目标） |
|------------|------|--------|------------------|
| Shader Jank | 有（Metal Impeller 静默） | `shader_compilation` | D0s |
| Heavy Compute | 有 | `heavy_compute` | D0s |
| PlatformChannel 高频 | 有 | `platform_channel_traffic` | D0s |
| GC / 堆涨 / 逼近上限 | 有 | 见 §2 / D0m | D0m |
| StreamSubscription 泄漏 | 有（增长检测） | `stream_resource_growth` | D0s |
| Event Loop Stall | **无独立 detector** | 用 `heavy_compute` + 帧 stall 相位 | 映射覆盖；一等名后置 |
| Widget 重建统计 | 有 | `rebuild_activity` | D0s |
| Excessive Repaint（运行时） | 有 | `excessive_repaint` | D0s |
| **Widget 树静态扫描** | 有（structural ≈1Hz） | `missing_repaint_boundary` / `layout_bottleneck` / `non_lazy_list` / `setstate_scope` / … | **D0s#9 须进事件**（stableId 去重） |

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
| 崩溃 / 未捕获异常流水 | 无独立崩溃事件流；仅操作失败等弱信号 |
| Platform Channel 耗时 | 不采集 |
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

阈值字段示例：`maxFrameCostMs`、`memoryIncreaseWarningMB`、`slowRequestMs`、`ttffWarningMs`、`leakRssRetainMb`、`leakConfirmRounds`（详见报告「环境与阈值」或 MCP `get_thresholds`）。

---

## 相关文档

- 产品 PRD / 报告信息架构：[Flutter-Perf-Agent.md](Flutter-Perf-Agent.md) §4.2、§4.3.2、§4.3.3  
- 使用教程：[flutter-perf-agent/docs/USAGE.md](../flutter-perf-agent/docs/USAGE.md)  
- 接入：[flutter-perf-agent/docs/INTEGRATION.md](../flutter-perf-agent/docs/INTEGRATION.md)  
