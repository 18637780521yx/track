# PRD：Flutter 完整 APM（开发 / 线上）

| 项 | 内容 |
|----|------|
| 产品 | Flutter-Perf-Agent → **完整 APM** |
| 版本 | Draft 0.1 |
| 日期 | 2026-10-23 |
| 关联 | 现有会话报告与工具见 [Flutter-Perf-Agent.md](Flutter-Perf-Agent.md)；事件目录见 [perf-events.md](perf-events.md) |
| 一句话 | **同一套 App SDK 内核**，开发/测试有 VM 就吃满（实时红帧 + UI bound 诱因尽量展示），线上无 VM 轻量采样；问题类型统一，能力按阶段降级、**有则用满**。 |

---

## 1. 背景与动机

### 1.1 为什么要完整 APM

- DevTools 适合人工实时剖析，**不会**自动把「用户点了什么」和卡顿/泄漏对齐成可归档报告。  
- 仅有开发/测试会话报告，**看不到**真实用户机型、网络、崩溃与长尾卡顿。  
- 仅有线上 SDK、没有开发期深挖，**定位成本高**（缺 CPU/堆/强制 GC 等 VM 能力）。

目标：补齐 **开发诊断闭环 + 线上可观测**，形成完整 APM，而不是两个互不相关的产品。

### 1.2 核心前提

**产品定位覆盖开发 / 测试 / 线上；VM 是开发（及本地测试 Profile）的增强手段，能连上就必须用满，而不是可选装饰。**

| | 开发（含本地测试） | 线上（Release） |
|--|-------------------|-----------------|
| VM Service | **有则必用**（Debug/Profile） | **无** |
| 强制 GC / AllocationProfile | 可 opt-in | **禁止** |
| flutter_skill / MCP 操控 | 有 | **无** |
| Sleuth 深度 detector + FrameVerdict | **有 VM 时完整诱因进报告** | 关闭或极简 |
| 开销预算 | 可接受偏高（为定位服务） | **严格**（采样、裁剪字段） |
| 权威产物 | 本地 JSON/HTML 会话报告 | 事件上报 + 云端聚合控制台 |

**能力原则：「有 VM 用 VM，无 VM 降级」**  
- 禁止把「只有 VM 才有的手段」做成**线上唯一**主路径。  
- 同样禁止：开发期明明有 VM / Sleuth Verdict，报告里却只显示「jank +N」这种空洞计数。

因此 PRD **按阶段切能力矩阵**，开发侧默认展示上限对齐 Sleuth full mode。

### 1.3 与现有产品的关系

| 现有（已落地/进行中） | 本 PRD 扩展 |
|----------------------|-------------|
| 会话账本、页面时间线、内联 `alert` | 仍是 **开发/测试** 主交互 |
| `jank` / `slow_frame` / `memory_leak` 等统一类型 | **开发与线上共用类型名**；线上子集 + 采样 |
| `leakOnlineEnabled` 首刀 | 扩展为完整线上管道 |
| 无完整云端控制台（旧非目标） | **本 PRD 把控制台纳入范围**（分里程碑） |

本地测试自动化（MCP 跑场景）归入 **开发阶段的一种用法**（Profile + VM），不单列第三产品线；验收与门禁仍可叫「测试模式」。

---

## 2. 目标与非目标

### 2.1 目标

1. **一套 SDK**：`PerfAgent` 内核；`mode=dev|online`（或 build flavor）切换采集强度。  
2. **统一问题模型**：告警/事件类型只表达「什么问题」（见 [perf-events.md](perf-events.md)），**不**用 `transition_*` 区分场景；位置由 route / step / 会话上下文表达。  
3. **开发阶段**：操作路径时间线 + 深挖（VM opt-in、Sleuth、可选 CPU/堆增强）+ AI/MCP 编排。  
4. **线上阶段**：启动、卡顿、内存趋势、路由面包屑、HTTP、崩溃/ANR、自定义埋点；采样可控；可上报到后端。  
5. **云端（APM 控制台）**：会话检索、版本对比、告警规则、崩溃聚合、漏斗/路由热力（分里程碑交付）。

### 2.2 非目标（本期明确不做或后置）

- 跨 App / 非 Flutter 原生工程一等支持  
- 嵌 DevTools Web UI 进报告  
- 线上开启 VM / 强制 GC  
- 完整方法级 CPU Profiler 进 **线上**（开发期可路线图接入）  
- 替代业务 BI / 完整日志平台（可对接，不自建全能日志）

---

## 3. 用户与场景

| 角色 | 阶段 | 典型场景 |
|------|------|----------|
| Flutter 开发 | 开发 | Cursor 跑登录流程；看某次 tap 后 jank；pop 后确认 `memory_leak` |
| 测试 / QA | 开发·测试模式 | CI 跑脚本；告警门禁失败则红 |
| 客户端负责人 | 线上 | 看某版本冷启动 P50/P90、崩溃率、慢接口 Top |
| 值班 / 支持 | 线上 | 按用户/会话拉面包屑 + 崩溃堆栈 |

---

## 4. 能力矩阵（开发 vs 线上）

图例：● 主路径　◐ 采样/可选　○ 不做　◆ 仅开发 VM opt-in

| 能力 | 开发 | 线上 | 说明 |
|------|------|------|------|
| 操作账本（tap/scroll/input + source） | ● | ○ | 线上无 MCP；可做采样「页面停留」而非全操作 |
| 页面级时间线 HTML/JSON | ● | ○（可导出单会话调试包） | 线上以事件流 + 控制台为主 |
| 帧卡顿 `jank` / `slow_frame` | ● **实时事件** + **有 VM 时附 UI/Raster 诱因**（现状仅 diff，不达标） | ● 采样事件（无阶段/函数级诱因） | 见 D0；线上永不依赖 VM |
| RSS / 内存涨 `memory_increase` | ●（操作窗 diff，保留） | ◐ | 进程 RSS，非 Dart 堆 |
| GC 压力 / 堆持续涨 / 堆逼近上限 | ● **实时事件**（现状未接入，仅偶发 sleuth_* / 转场 sleuthHits） | ◐ 采样 | 见 **D0m**；开发有 VM 时用满 Sleuth MemoryPressure |
| 真泄漏 `memory_leak`（WeakRef 登记） | ● | ◐ | 线上采样率；**禁止**强制 GC |
| RSS 辅证 `memory_retain_rss` | ● | ◐ | 不单独定罪 |
| 冷启动 `slow_cold_start` / TTFF·TTI | ● | ● | 线上核心指标 |
| HTTP 慢请求 / 错误 | ●（Sleuth+账本） | ● | 线上自建轻量拦截或复用现有 HttpOverrides 裁剪版 |
| Widget 反模式 / 重建风暴 | ● Sleuth | ○ | Profile 已降级；线上成本高 |
| VM 深挖（GC + AllocationProfile） | ◆ | ○ | `evidence=vm_deep` |
| CPU Profiler / Trace 导出 | ◐ 路线图 | ○ | 对齐操作标记后导出 |
| 崩溃 / IsolateError / Zone | ◐→● | ● | 线上必做；开发也建议开 |
| ANR / 看门狗 | ◐ | ●（Android 优先） | |
| 自定义埋点 / 面包屑 | ● | ● | |
| MCP / flutter_skill | ● | ○ | |
| 云端告警与版本对比 | ○→● | ● | 控制台里程碑 |

---

## 5. 产品架构

```text
┌─────────────────────── 开发机 ───────────────────────┐
│  Cursor / CI                                         │
│       │ MCP                                          │
│  Perf-Agent MCP ──VM/skill──► App (Profile)          │
│                               │                      │
│                    PerfAgent SDK（dev 强度）           │
│                    SessionJournal → JSON/HTML          │
│                    Sleuth + 可选 VM deep               │
└──────────────────────────────────────────────────────┘

┌─────────────────────── 用户设备 ─────────────────────┐
│  App (Release)                                       │
│    PerfAgent SDK（online 强度 + sampleRate）         │
│    事件：lifecycle / route / jank / net / crash …    │
│              │ HTTPS 批量上报                         │
└──────────────┼───────────────────────────────────────┘
               ▼
        APM Collector / 存储
               ▼
        APM Console（检索、看板、告警、崩溃聚合）
```

**原则**

1. SDK 内 **一套事件 schema**（`type` + `alertType` + `route` + `sessionId` + `appVersion` …）。  
2. 开发会话报告 = schema 的「高密度、带 step」投影；线上 = 「低密度、可采样」投影。  
3. Collector 与 Console 可自建或先适配现有后端；契约先于实现冻结。

---

## 6. 功能需求

### 6.1 开发阶段（Dev APM）

**已有（保留并演进）**

- MCP：`start/stop`、`tap`/`scroll`/`input`、`wait_lifecycle`、按需截图等  
- 统一账本 + 手动手势；`mcp|manual`  
- 时间线：`lifecycle` / `page` / `transition`；性能问题 **内联**为 `alert`  
- 告警：`jank`、`slow_frame`、`memory_increase`、`memory_leak`、`memory_retain_rss`、`slow_cold_start`、`sleuth_*`  
- 转场泄漏主路径：WeakRef / 多轮；VM 深挖 opt-in  
- **卡顿（现状）**：MCP/手动路径对操作前后 Sleuth `jankCount`/`p90` 做差 → 近似归因，**不够准**  
- **内存压力（现状）**：Sleuth 有 `gc_pressure` / `heap_growing` / `heap_near_capacity`，**未**作一等实时事件；最多操作窗 `sleuth_*` 或转场 `sleuthHits`  

**本 PRD 增量**

| ID | 需求 | 优先级 |
|----|------|--------|
| **D0** | **实时卡顿 + 有 VM 时诱因尽可能展示（下一刀）** | **P0** |
| **D0m** | **实时内存压力事件（与 D0 同刀/紧随）** | **P0** |
| **D0s** | **Sleuth 一等 detector → 触发即进时间线（清单见下，与 D0 同批）** | **P0** |
| D1 | 崩溃/断言捕获写入会话（与操作时间线对齐） | P0 |
| D2 | 可选整段 Timeline/CPU 导出归档（D0 已含帧级诱因；本项为原始 trace 附件） | P2 |
| D3 | 会话对比（相对 baseline JSON：告警数、P90、RSS） | P1 |
| D4 | CI 门禁配置文件（哪些 `alertType` 失败构建） | P0 |
| D5 | 人手输入记入 `input:`（脱敏） | P2 |
| D6 | 开发报告一键「标记为线上同类问题」映射（便于知识库） | P2 |

#### D0 实时卡顿 + UI bound 诱因（规范）

**总原则：工具服务开发/测试/线上；开发/测试有 VM 时，卡顿事件必须尽量带上 Sleuth 已能给出的诱因，禁止只报空洞计数。**

1. **触发**：帧超预算（Sleuth / `FrameTiming`，默认 `maxFrameCostMs=16`）→ **立刻**写入账本事件（`alert`+`jank` 或一等 `jank`，实现定一种）。  
2. **基础字段（无 VM 也要有）**：`at`、`frameMs`、`uiMs`/`rasterMs`（若有）、`route`、最近 `stepId`；时间线按 `at` 内联。  
3. **有 VM（Sleuth `FrameVerdict` full / correlated）时，`detail` 尽量带满：**  
   - `suspectedPhase`：`build` \| `layout` \| `paint` \| `raster` \| …  
   - `buildMs` / `layoutMs` / `paintMs`（Timeline 分项）  
   - `reason`：Verdict 可读说明  
   - `relatedIssues[]`：与本帧相关的 detector（重建风暴、SaveLayer、慢请求等）  
   - `topFunctions[]`：有则附上（CPU 归因，可异步补全同一事件或 follow-up）  
   - `vmMode`: `full` \| `basic`（便于报告标明「本次有无 VM 诱因」）  
4. **HTML**：jank 行展开显示「疑似阶段 + 相关 issue + 函数 Top」（有则显示，无则降级为耗时）。UI bound 时阶段/相关 issue **不得省略**（有数据却不展示视为未完成 D0）。  
5. **废弃主路径**：仅操作窗 `jankCount` diff；diff 可留作页/步摘要。  
6. **节流**：开发默认可逐帧或轻合并；合并时保留最严重一帧的诱因字段。  
7. **线上**：无 VM；同事件模型但无 phase/functions；采样（O3）。

#### D0m 实时内存压力（规范）

与卡顿同一哲学：**Sleuth 已检出 → 立刻进账本**，不要等操作前后 diff，也不要只埋在转场 `sleuthHits` 里。

| `alertType`（建议与 Sleuth `stableId` 对齐） | 含义 | 典型依赖 |
|-----------------------------------------------|------|----------|
| `gc_pressure` | GC 过于频繁 | VM GC 事件流（开发 Profile） |
| `heap_growing` | Dart 堆持续上涨（斜率） | VM AllocationProfile / 堆采样 |
| `heap_near_capacity` | 堆/进程内存逼近预算上限 | 需配置 `memoryBudgetBytes`（Sleuth）；常与 `heap_growing` 同评 |
| `native_memory_growing` | 原生/外部内存斜率异常（可选同批） | 同上 |

规范要点：

1. **触发**：Sleuth `MemoryPressureDetector`（或等价）latch/emit 时，SDK 监听并 **立即** `SessionJournal` 追加 `type=alert` + 上表 `alertType`。  
2. **`detail`**：`stableId`、`title`/`message`、关键数值（斜率、GC/min、usage/capacity、RSS）、`route`、`vmMode`；有 allocator Top 则带上。  
3. **时间线**：按 `at` 落入当时页面/转场；HTML 警示样式展开数值。  
4. **与现有关系**：`memory_increase`（RSS 步差）保留；`heapIncreaseWarningMB` 若继续使用须接到真实堆指标或废弃以免误导。转场 `sleuthHits` 可保留作泄漏辅证，**不能替代**本事件。  
5. **线上**：无完整 VM 时降级（RSS 趋势采样 / 省略 GC 细项）；类型名仍统一，字段可空。

#### D0s Sleuth detector → 会话事件（开发有则用满）

**原则：Sleuth 已具备的告警，开发/测试会话里一律「latch 即写入账本」**，禁止长期只靠操作窗 `sleuth_issues` 笼统汇总。`alertType` 与 Sleuth `stableId` 对齐（便于对照文档）。

| # | 能力 | Sleuth | 建议 `alertType` | 备注 |
|---|------|--------|------------------|------|
| 1 | Shader Jank | `ShaderJankDetector` → `shader_compilation` | `shader_compilation` | **Impeller Metal 无事件（设计如此）**；Vulkan pipeline / Skia shader 有效；需 VM Timeline |
| 2 | Heavy Compute | `HeavyComputeDetector` → `heavy_compute` | `heavy_compute` | UI 线程过长同步计算；VM |
| 3 | PlatformChannel 高频 | `PlatformChannelDetector` → `platform_channel_traffic` | `platform_channel_traffic` | VM |
| 4 | GC / 堆涨 / 逼近上限 | MemoryPressure → 见 **D0m** | `gc_pressure` / `heap_growing` / `heap_near_capacity` | 已单列 D0m |
| 5 | Stream 泄漏（忘 cancel） | `StreamResourceDetector` → `stream_resource_growth` | `stream_resource_growth` | 观察 StreamSubscription 等存活增长；非逐个「未 cancel」静态分析 |
| 6 | Event Loop Stall | **无独立 detector** | （映射）`heavy_compute` + 帧 `pipelineStall`/`schedulerDelay` / `sustained_jank` | 用邻近信号覆盖；若要一等 `event_loop_stall` 需另开增强 |
| 7 | Widget 重建统计 | `RebuildDetector` → `rebuild_activity` | `rebuild_activity` | 频繁 rebuild；Profile 下能力可能降级 |
| 8 | Excessive Repaint（运行时） | `RepaintDetector` → `excessive_repaint` | `excessive_repaint` | 运行时重绘占比；与下行「结构扫描」不同 |
| 9 | **Widget 树静态扫描** | `DetectorLifecycle.structural`（约 1Hz 树遍历） | 与各 `stableId` 对齐 | **须进事件**（见下表）；不依赖 VM |

**Widget 树静态扫描（structural）→ 事件映射（开发默认全开进账本）：**

| Sleuth detector（例） | 典型 `alertType` / stableId | 含义 |
|----------------------|-----------------------------|------|
| RepaintBoundary | `missing_repaint_boundary` / `excessive_repaint_boundary` | 缺边界 / 边界过多 |
| LayoutBottleneck | `layout_bottleneck` / `wrap_layout_bottleneck` | 布局瓶颈（如深层 Intrinsic） |
| ListView / Sliver | `non_lazy_list` / `non_lazy_shrinkwrap` / … | 非懒加载列表等 |
| SetStateScope | `setstate_scope` | setState 范围过大 |
| KeepAlive | `excessive_keep_alive:*` | KeepAlive 过多 |
| CustomPainter | `always_repaint_painter` / `frequent_repaint_painter` | Painter 乱重绘 |
| Image / Font 等 | `uncached_images` / `runtime_font_loading` / … | 结构/加载类问题 |
| 自定义 structural | 宿主 `stableId` | 一并转发 |

扫描节流跟 Sleuth（约每秒）；**同一 stableId 去重**，仅在新出现或升级 severity 时再发事件，避免刷屏。

**接入规范（与 D0/D0m 相同）：**

1. SDK 订阅 Sleuth issue 增量（或轮询差分 stableId）→ 新 issue **立即** `SessionJournal` 事件（含 **structural** 与 runtime/vm 类）。  
2. `detail`：stableId、severity、title、数值、route、`observationSource=structural|…`、可选 relatedIssues。  
3. HTML：内联 `alert` 行；可按类别筛选（后续）。  
4. 线上：structural 可采样或关闭（成本与树规模相关）；VM-only 关闭。

### 6.2 线上阶段（Online APM）

| ID | 需求 | 优先级 |
|----|------|--------|
| O1 | `PerfAgent.startOnline({ sampleRate, endpoint, appKey })` | P0 |
| O2 | 冷启动、前后台、路由面包屑（采样） | P0 |
| O3 | 卡顿：与 D0 同模型的实时/合并 jank 事件 + 采样上报（非「仅会话结束吐一个计数」） | P0 |
| O4 | 内存采样：周期 RSS / 与 D0m 同类型的降级事件（无 VM 细项） | P1 |
| O5 | `memory_leak` 线上采样（登记对象 + 采样率；无 GC） | P1 |
| O6 | HTTP：耗时、状态码、域名；慢请求/失败率 | P0 |
| O7 | 崩溃 + FlutterError + Isolate 未捕获；ANR（Android） | P0 |
| O8 | 自定义 `track(name, props)` / 面包屑 | P0 |
| O9 | 批量上报、失败重试、日上限、用户同意/开关 | P0 |
| O10 | 隐私：默认脱敏 URL query、关闭 body；合规开关 | P0 |

### 6.3 云端控制台（APM Console）

| ID | 需求 | 优先级 |
|----|------|--------|
| C1 | 接收与校验事件；按 app/version/os 索引 | P0 |
| C2 | 看板：启动耗时、崩溃率、卡顿率、慢请求 Top | P0 |
| C3 | 崩溃聚合（指纹）与符号表（至少 Dart；原生后置） | P0 |
| C4 | 告警规则（阈值、版本回归）与通知（Webhook/邮件） | P1 |
| C5 | 单用户/会话面包屑回放（路由 + 关键事件） | P1 |
| C6 | 与开发会话报告 ID 关联（可选：同 `issueKey`） | P2 |

### 6.4 统一问题类型（跨阶段）

沿用 [perf-events.md](perf-events.md) 的类型哲学，线上增加但不改名：

| 类型 | 开发 | 线上 |
|------|------|------|
| `jank` / `slow_frame` | ● 实时 + VM 诱因 | ● 采样 |
| `gc_pressure` / `heap_growing` / `heap_near_capacity` | ● 实时（D0m） | ◐ 降级采样 |
| `native_memory_growing` | ◐ | ◐ |
| `shader_compilation` / `heavy_compute` / `platform_channel_traffic` | ● 实时（D0s，多需 VM） | ○ |
| `stream_resource_growth` | ● 实时（D0s） | ◐ |
| `rebuild_activity` / `excessive_repaint` | ● 实时（D0s） | ○ |
| Widget 树静态扫描（`missing_repaint_boundary` / `layout_bottleneck` / …） | ● 扫描命中即事件（D0s#9） | ◐ 可关 |
| `memory_increase`（RSS 步差） | ● | ◐ |
| `memory_leak` / `memory_retain_rss` | ● | ◐ |
| `slow_cold_start` | ● | ● |
| `sleuth_*`（笼统汇总，逐步被一等类型替代） | ◐ | ○ |
| `crash` / `anr` | ● | ● |
| `slow_request` / `http_error`（可升一等类型，或仍经 network+规则） | ● | ● |
| `custom` | ● | ● |

**禁止**再引入 `transition_jank` 这类「场景写进类型名」的枚举。

---

## 7. 数据与隐私

### 7.1 公共事件字段（最小集）

```text
schemaVersion, env(dev|online), appId, appVersion, buildNumber,
platform, osVersion, deviceClass(optional),
sessionId, userId(optional/hashed),
at, type, route?, alertType?, ok?,
detail{}, sampleRate?
```

### 7.2 隐私默认

- 不上报请求/响应 **body**（除非显式 debug 包）  
- URL 默认 strip query 中的 token/phone  
- `input` 密码字段永远 `***`  
- 线上默认 **采样**；可远程配置关闭某类事件  

### 7.3 开销目标

| 阶段 | 目标 |
|------|------|
| 开发 Profile | 采集叠加帧影响 &lt; 10%（沿用现 PRD） |
| 线上 | CPU &lt; 2%、流量可配日 cap；崩溃通道优先保证投递 |

---

## 8. 里程碑

| 里程碑 | 范围 | 验收要点 |
|--------|------|----------|
| **M0**（现状锚定） | 开发会话报告 + 内联告警 + 泄漏主路径 | 已具备；文档与类型统一完成 |
| **M0.5 实时卡顿/内存/Sleuth 一等事件（下一刀）** | **D0 + D0m + D0s** | 红帧+诱因；内存压力；runtime/VM detector + **Widget 树静态扫描** **latch→时间线**（不再只靠 sleuth_*） |
| **M1 开发加固** | D1 崩溃进会话、D4 CI 门禁 | 一次失败用例报告含 crash；CI 可红 |
| **M2 线上 SDK** | O1–O3、O6–O10 | Release Demo 可上报启动/卡顿/HTTP/崩溃到 collector mock |
| **M3 泄漏线上采样** | O4–O5 | 采样开关下 WeakRef 泄漏事件可见且无 GC |
| **M4 控制台 MVP** | C1–C3 | 看板 + 崩溃列表可演示 |
| **M5 告警与回放** | C4–C5、D3 | 版本回归告警；面包屑回放 |
| **M6 深挖增强** | D2、可选 CPU | 开发期 trace 与 step 对齐 |

---

## 9. 风险与约束

| 风险 | 应对 |
|------|------|
| 线上误用 VM API | 编译期 / runtime 双开关；Release assert 关闭 |
| 采样导致漏报泄漏 | 文档标明置信度；开发门禁仍 WeakRef 全开 |
| HttpOverrides 冲突 | 可插拔；与业务客户端协调单一入口 |
| 控制台范围膨胀 | M4 只做检索+崩溃+三类看板 |
| 与现有 Flutter-Perf-Agent PRD 双文档漂移 | 本文件管「完整 APM」；旧 PRD 管「当前工具实现细节」；事件类型以 perf-events 为准 |

---

## 10. 成功指标（产品）

**开发**

- 典型流程（登录→列表→进出详情）可自动出报告；泄漏/卡顿门禁可用于 CI  
- 问题从「有告警」到「能指出操作/路由」无需再开 DevTools 的比例提升（定性访谈）

**线上**

- 崩溃上报到达率、冷启动与卡顿大盘可按版本对比  
- 重大版本发布前后 24h 可回答：崩溃率 / 启动 P90 / 慢请求 Top 是否回归  

---

## 11. 文档与入口

| 文档 | 职责 |
|------|------|
| **本文件** | 完整 APM：开发 vs 线上范围、矩阵、里程碑 |
| [Flutter-Perf-Agent.md](Flutter-Perf-Agent.md) | 当前 MCP + 会话报告实现向 PRD |
| [perf-events.md](perf-events.md) | 事件/告警类型权威目录 |
| [design/report-timeline-v4-inline-alerts.jpg](design/report-timeline-v4-inline-alerts.jpg) | 开发报告信息架构 |

---

## 12. 开放问题（实现前需拍板）

1. 线上 Collector：**自建**还是先对接公司现有网关？  
2. 用户标识：匿名 deviceId 是否足够，是否要登录态 hashed userId？  
3. `slow_request` 是否升为与 `jank` 同级的一等 `alertType`（推荐：**是**，便于控制台规则）？  
4. 测试 CI 是否强制 Profile + `--no-dds`？  

（默认建议：1 先 mock Collector；2 deviceId + 可选 hashed userId；3 升一等；4 是。）
