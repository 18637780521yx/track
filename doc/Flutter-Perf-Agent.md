# PRD：Flutter AI性能测试Agent
> 项目代号：Flutter-Perf-Agent
版本：V1.1
编写日期：2026-10-15
最近更新：2026-10-20
目标：一套贯穿 **开发 / 测试 / 线上** 的 Flutter 性能与质量 SDK +（开发/测试期）AI 编排能力。
一句话目标：开发期用 flutter_skill + Sleuth 辅助定位；测试期自动跑场景出报告；线上轻量采集性能、崩溃与埋点日志——**同一套 App SDK 账本与路由/转场模型，能力按阶段降级，不绑死 VM。**

## 1. 产品概述
### 1.1 背景
现有Flutter生态缺少开源的「大模型自主探索UI自动化 + 内嵌性能采集」一体化工具。
传统自动化工具依赖固定脚本；DevTools只能人工手动录制trace，无法和UI动作时序自动对齐。
本项目将 **flutter-skill（MCP UI操控）**、**Sleuth（开发/测试期深度采集）** 与 **App SDK 统一账本** 组合；长期演进为三阶段共用内核。

### 1.2 产品目标（三阶段）

| 阶段 | 作用 | 主要能力 | 依赖 |
|------|------|----------|------|
| **开发** | 辅助开发定位 | flutter_skill 操控、Sleuth 检测器、本地 JSON/HTML 报告、转场/页面时间线 | Debug/Profile；VM 可选（UI 自动化需要） |
| **测试** | 自动执行场景完成测试 | MCP/脚本驱动流程、统一账本、告警门禁、转场卡顿与泄漏检测 | Profile 优先；VM 用于自动化，**泄漏主路径不依赖强制 GC** |
| **线上** | 自动收集性能/崩溃/埋点 | 轻量采样（FPS/卡顿/内存趋势）、路由面包屑、崩溃与自定义埋点上报 | **Release 可用**；无 VM、无强制 GC、无 flutter_skill |

- **统一操作账本（App SDK）**：开发/测试期权威报告源；线上为采样与事件流水（可裁剪字段）
- MCP 只负责开发/测试期编排，不独占数据所有权

### 1.3 非目标（当前 V1 迭代不做；路线图另述）
1. V1 **先做**开发 + 测试本地闭环；线上采集为明确路线图，接口预留、实现后置
2. 不支持跨App操作
3. V1 不做完整云端 APM 控制台（线上只定义 SDK 侧采集与上报契约）
4. V1不支持多设备并发测试
5. 不做完整堆快照 Diff **图形化**；泄漏见 4.3.3（**不依赖 VM 强制 GC 作为主路径**）
6. 不支持iOS真机深度无障碍（优先Android模拟器/本地桌面Flutter）
7. 本期不做 App Size / Deep links
8. 线上阶段不连接 DevTools / VM Service
9. 不嵌 DevTools Web UI

### 1.4 设计约束：不为「测得准」牺牲三阶段共用
- **禁止**把「VM `collectAllGarbage` / AllocationProfile」做成泄漏检测的唯一主路径（线上无 VM）
- VM 深度能力仅作为开发/测试期的 **可选增强**（opt-in），报告中标注 `evidence=vm_deep`
- 主路径必须是 **App 内可运行** 的：路由配对、资源登记（WeakReference/Finalizer）、多轮进出趋势、Sleuth 在非 Release 下的检测器

## 2. 用户角色
**目标用户：Flutter开发者 / 移动端测试工程师**
- 使用Cursor + MCP，自然语言发起App自动化性能测试
- 不需要手写测试脚本，直接用自然语言描述测试流程
- 在开发阶段做回归测试、卡顿检测、内存增长检查

## 3. 核心架构
```
Cursor(LLM Client) ←MCP(stdio JSON-RPC)→ Flutter-Perf-Agent MCP Server
                                                ↓ 编排 UI（VM / flutter_skill）
                                  App SDK：SessionJournal（统一账本）+ SdkReportWriter
                                     ↑ 手动点击 hitTest 记账          ↑ MCP POST /session/step
                                  Sleuth（FPS/Jank/内存/网络）
                                     ↓ session/stop
                                  App 内生成 JSON/HTML 报告（权威产物）
```

### 模块清单
1. **MCP Server模块（PC端，dart）**
    - 对外暴露MCP工具给Cursor
    - 管理和App端flutter-skill SDK的通信
    - 将 MCP 动作步骤写入 App SDK 统一账本；触发 session stop
    - 可读回 SDK 生成的报告路径（可选在 PC 侧再落一份副本）
2. **App SDK模块（嵌入被测Flutter App，dev依赖）**
    - flutter-skill：语义树读取、Pointer手势注入（点击/滑动/输入）
    - Sleuth：帧时序、卡顿、内存、网络、Widget反模式采集
    - **SessionJournal（统一操作账本）**：记录 MCP / 手动 两类步骤与性能 diff
    - **ManualGestureRecorder**：手动点击时 hitTest 解析控件并记账
    - **SdkReportWriter**：会话结束时在 App 侧生成 JSON/HTML 报告
3. **报告模块**：以 App SDK 为权威产出；MCP 与手动共用同一套产物

## 4. 功能需求（V1.0）
### 4.1 MCP工具集（暴露给Cursor）
> 所有工具通过MCP注册，Cursor大模型可自动调用
1. `start_perf_test`
    - 描述：启动性能测试会话，初始化连接App，重置Sleuth采集器
    - 参数：testName（测试名称）、waitStableMs（页面稳定等待时间，默认500ms）
    - 返回：会话ID
2. `stop_perf_test`
    - 描述：停止测试，停止性能采集，汇总全部指标，生成报告
    - 参数：sessionId
    - 返回：报告路径、指标摘要、告警列表
3. `tap`
    - 描述：点击控件（优先语义树定位，失败降级无障碍）
    - 参数：targetDesc（控件描述，例如“登录按钮”）
    - 内部逻辑：
      1. 操作前：读取Sleuth性能快照(before)
      2. 执行flutter-skill点击动作
      3. 等待页面稳定（waitStableMs）
      4. 操作后：读取Sleuth性能快照(after)
      5. 计算指标diff，上报到MCP服务
    - 返回：操作结果、截图、本次操作性能指标diff
4. `scroll`
    - 描述：滑动页面
    - 参数：targetDesc、direction、distance
    - 打点逻辑同tap，前后采集性能快照
5. `input_text`
    - 描述：输入文字到输入框
    - 参数：targetDesc、text
    - 打点逻辑同上
6. `get_ui_snapshot`
    - 描述：获取当前页面UI树+截图，供LLM分析页面状态
7. `get_perf_threshold_config`
    - 描述：读取性能阈值配置（可自定义告警阈值）

### 4.2 性能采集指标（Sleuth输出）
- 帧率：平均FPS、P90帧耗时、Jank卡顿次数
- 内存：Dart堆内存使用量、内存增量
- 网络：慢请求列表（请求耗时、接口地址）
- Widget检测：Widget重建风暴、缺少RepaintBoundary、SaveLayer检测告警
- 每条指标附带时间戳，绑定对应的操作步骤

### 4.3 测试报告输出
输出2种产物（**由 App SDK 生成**，MCP / 手动共用；`schemaVersion ≥ 9`）：
1. JSON原始报告：机器可读，用于CI对比回归
    - 测试元信息：测试名称、开始结束时间、profile/debug模式、`reportOwner`
    - 权威数据：`steps[]`（含 `events[]`）、`alerts[]`、阈值、Sleuth diagnose
    - **派生视图** `view`（写报告时生成，不替代 `steps`）：
      - `view.events`：打平后的全量事件（含 stepId / route / source）
      - `view.timeline`：**按时间排列的模块段**；每段内嵌该段 `events`
      - `view.stats`：会话级摘要（网络数、avg FPS、RSS 峰值等）
2. HTML可视化报告（可读）
    - 结构见 **4.3.2**（时间线内嵌模块，无下方独立模块堆叠区）
    - 告警标红；截图 / 网络详情可展开嵌入

### 4.3.1 统一操作账本（MCP + 手动）
- **权威账本在 App SDK**（`SessionJournal`），不在 MCP 进程内独占
- **MCP 路径**：每次 `tap`/`scroll`/`input_text`/手势类 `skill_call` 完成后，经 Bridge `POST /session/step` 写入账本；动作期间开启 `mcp_guard`，避免手动录制把合成指针再记一遍
- **手动路径**：会话开启后（含首次手动点击自动开会话），`ManualGestureRecorder` 监听指针抬起 → hitTest 解析控件 → 采前后 Sleuth/RSS → 写入同账本；跨路由时写入 `navigate`（`transitionKind`）
- **结束**：`POST /session/stop`（或 App 内「结束录制」）由 SDK 写出 JSON/HTML，返回报告路径
- **区分多控件**：优先 `ValueKey`，其次 label/hint/可见文案，再次坐标；与 flutter_skill 定位策略对齐
- **非目标（本迭代）**：完整手动手势回放、精确区分所有自定义手势；极简控件无 Key/文案时可能记为 `tap@x,y`

### 4.3.2 报告信息架构：时间线内嵌模块
> 核心原则：**模块不是时间线外的独立分区，而是时间线上的段（segment）；事件嵌在模块段内部。**

**HTML 页面结构（自上而下）：**
1. **摘要条**：会话名、总耗时、步骤/成功/告警/网络数、会话级 avg FPS / RSS 峰值等
2. **全会话时间线（主视图）**：按时间从上到下排列的**模块段**；顶部 chips 按模块类型筛选（全部 / 启动 / 页面 / 转场 / 告警）
3. **环境与阈值**（页脚轻量区）：阈值、Sleuth diagnose、说明文案

**时间线内的模块类型：**

| 模块 | 何时成段 | 段内内容 |
|------|----------|----------|
| **App 启动** | `cold_start` | TTFF/TTI、冷启动分阶段表、首屏截图 |
| **页面** | 同 route 连续停留期间 | 该页上的 screenshot / action / network / 页内 alert；附步骤 diff 摘要（耗时、Δmem、Jank） |
| **转场** | `navigate` 事件 | from → to、`transitionKind`；后续见 **4.3.3** 补齐窗口指标与泄漏检测 |
| **告警** | 无法挂到当前页面段的会话级 alert | 告警正文；可锚定回时间线 |

**事件类型（挂在模块段内）：**  
`cold_start` / `screenshot` / `action` / `network` / `navigate` / `alert`

**明确不做（避免与主时间线重复）：**
- 不在时间线下方再做独立的「网络总表 / 性能总表 / 截图墙 / 操作清单」大分区
- 网络请求展示在**页面模块**的内嵌时间线中（可展开头/体）；会话级网络计数放在摘要条
- 会话级性能概览（FPS/RSS）放在摘要条，逐步 Δmem 挂在**页面模块**内

**派生与兼容：**
- `protocol.buildReportView(report)` 从 `steps`/`alerts` 派生 `view`；HTML 优先渲染 `view.timeline`（模块段）
- 旧报告无 `view` 或仍为扁平事件时，渲染前现场派生，保证 MCP / SDK HTML 一致

### 4.3.3 转场模块：卡顿 / 真泄漏（**不依赖 VM 强制 GC**）
转场是卡顿与泄漏高发区。当前已具备：`navigate` + `transitionKind`（缺省 `route_change`）。

> **原则**  
> 1. 真泄漏主路径必须 **开发 / 测试 / 线上** 都能跑（线上无 VM → **禁止**把强制 GC / AllocationProfile 当唯一依赖）。  
> 2. RSS **不单独定罪**。  
> 3. VM `collectAllGarbage` + AllocationProfile = **测试/实验室 opt-in 深挖**，报告标 `evidence=vm_deep`，默认关闭。

**目标形态（转场段）：**
```
[转场] pop  /detail → /list · 280ms
  动画 280ms · jank +3 · P90 24ms
  泄漏：XxxController 仍可达（WeakRef 未释放）· tracked=1 alive
  多轮：同路由 3 次进出，存活对象阶梯 +1/+1/+1
  （可选深挖）AllocationProfile Δ …  evidence=vm_deep
```

#### A. 真泄漏主路径（App 内，无强制 GC）

核心：**对象仍被引用 = 泄漏**；不必先 GC 再数堆。

1. **资源登记（推荐接入点）**  
   - 页面/Controller 创建或 SDK hook（GetX/Navigator）时：`track(route, object)` → `WeakReference` + `Finalizer`  
   - pop / 页面 dispose 期望路径：对象应变为不可达 → Finalizer 回调 / WeakRef 清空  

2. **pop 后判定（不强制 GC）**

   | 结果 | 含义 | 告警 |
   |------|------|------|
   | settle 后 WeakRef **仍指向对象** | 仍被持有 → **真泄漏（高置信）** | `transition_memory_leak` |
   | WeakRef 已空 / Finalizer 已触发 | 已可回收 | 通过 |
   | 一时仍在、稍后多轮观察仍在 | 持续可达 | `transition_memory_leak` |
   | 仅 RSS 涨、无登记对象存活 | 缓存或未登记泄漏 | `transition_memory_retain_rss`（辅证） |

   - settle 用于等 dispose 链路跑完，**不是**等强制 GC  
   - 自然 GC 未跑时：不可达对象可能暂时「还在堆上」，但 WeakRef 在对象回收前仍可能非空——因此 **以「是否仍被强引用图握住」为准**；实现上优先检查业务登记的强引用是否按生命周期 `untrack`，并对 `track` 的对象看 WeakRef；对「已 untrack 但仍被别的根抓住」用 WeakRef 在后续帧/下一次同路由进入时复检  

3. **多轮进出（提置信、线上友好）**  
   - 同 route push↔pop ≥ `leakConfirmRounds`（测试默认 2～3；线上用滑动窗口统计）  
   - 每轮 pop 后「仍存活的已登记实例数」**单调不减 / 阶梯上涨** → 泄漏  
   - 不依赖 VM，Release 亦可做（只要有登记或可 hook 的 Controller）  

4. **Sleuth（开发/测试增强，非线上必选）**  
   - 绑定 `stream_resource_growth` / `heap_growing` 等，`sourceRoute` 归因到转场段  
   - 与 WeakRef 结果合并；Sleuth 单独 hit 时可出 `transition_memory_leak`（注明 `evidence=sleuth`）  

5. **VM 深挖（opt-in，仅开发/测试）**  
   - 开关：`leakVmDeepProbe=false`（默认）  
   - 开启后才：可选 `collectAllGarbage` + `getAllocationProfile` 类 Δ，结果 `evidence=vm_deep`  
   - **不得**作为线上或默认测试门禁的唯一条件  

6. **告警分级**  
   - `transition_memory_leak`：主告警（仍可达 / 多轮阶梯 / Sleuth 高置信）  
   - `transition_memory_retain_rss`：辅证  
   - `transition_jank`：转场卡顿  

#### B. 分阶段怎么用

| 阶段 | 泄漏怎么抓 | 强制 GC |
|------|------------|---------|
| 开发 | track + WeakRef；Sleuth issues；报告时间线 | 可选手动深挖 |
| 测试 | 同上 + 多轮场景；门禁用 WeakRef/多轮，不用强制 GC | 仅 `leakVmDeepProbe` 实验室 |
| 线上 | 轻量 track（采样率）+ 路由面包屑 + 多会话聚合；崩溃/埋点并行 | **永不** |

#### C. 转场窗口与种类

1. **`transitionKind`**：`push` / `pop` / `replace` / `modal_*`；否则 `route_change`  
2. **时间窗**：T0→T1→（pop）T2 settle；采 FPS/jank/P90、截图（线上可关截图）；泄漏看登记对象存活  
3. **push↔pop 配对账本**：泄漏挂在 **pop 段**

#### D. 落地优先级

| 阶段 | 内容 | 状态 |
|------|------|------|
| **V1** | push/pop；资源 track/WeakRef；pop 后仍可达 → `transition_memory_leak`；转场 jank；RSS 辅证；**默认不做强制 GC** | 已实现（0.8.0） |
| **V2** | **多轮确认**（0.8.2）+ **GetX/Navigator 自动 hook**（`PerfDi` / `instrumentGetPages` / `navigatorObservers`，0.8.3） | **部分已实现**；Sleuth stream 绑定、线上采样仍规划 |
| **V3** | opt-in VM 深挖；modal/Hero；门禁策略 | 规划 |

#### E. 配置扩展

- `transitionSettleMs`（`PerfAgent.ensureInitialized`，已接）  
- `leakConfirmRounds`（已接，默认 2）  
- `leakTrackEnabled`（已接） / 采样率（线上，规划）  
- `leakVmDeepProbe`（默认 `false`，规划）  
- 沿用 `maxFrameCostMs` 判转场卡顿

### 4.4 配置能力
支持配置文件 `perf_agent_config.json`
- 性能告警阈值：
  - maxFrameCostMs：单帧最大耗时阈值（默认16ms）
  - memoryIncreaseWarningMB：单次内存上涨告警阈值（默认5MB）
  - slowRequestMs：慢接口阈值（默认300ms）
  - App SDK + MCP JSON `transition`：`transitionSettleMs` / `leakConfirmRounds` / `leakTrackEnabled` / `leakRssRetainMb`（开会话下推到 Bridge，0.8.5 已对齐）
  - （规划）leakVmDeepProbe / 线上采样率
- 页面等待稳定默认时长
- 是否开启网络采集开关
- 是否开启Widget反模式检测开关

## 5. 非功能需求
1. **性能开销**：采集叠加后，对被测App帧率影响控制在10%以内
2. 稳定性：单条测试流程（5~10步操作）成功率 ≥ 85%
3. 兼容性：支持Flutter Android模拟器 / Windows桌面Flutter；V1优先Android模拟器
4. 可观测：日志输出，可开启debug日志查看通信、打点详情
5. 可扩展：后续可替换采集库（替换Sleuth为自研采集器，无需改动MCP上层）

## 6. 技术约束 & 风险
### 约束
1. 被测Flutter项目必须引入dev依赖：`flutter_skill` + `sleuth`，仅在dev环境打包
2. 测试必须使用 `flutter run --profile` 获取可信性能数据；debug仅用于快速验证功能
3. Sleuth在profile模式下Widget rebuild检测能力降级
4. flutter-skill降级无障碍模式，需要Android开启无障碍权限

| 风险 | 风险等级 | 应对方案 |
| ---- | ---- | ---- |
| LLM识别控件错误，误点击 | 中 | 增加页面稳定等待；增加重试机制；日志记录失败动作 |
| 打点时机不准，页面未渲染完成就读取指标 | 高 | 页面稳定等待机制；增加轮询判断页面状态 |
| Sleuth + flutter-skill叠加带来额外性能开销 | 中 | 在报告中标注【采集工具引入额外开销】；profile模式执行 |
| HttpOverrides冲突（Sleuth网络拦截） | 低 | 配置项可关闭Sleuth网络采集 |

## 7. MVP开发迭代计划（分3阶段）
### Phase1：基础打通（1~2周）
目标：验证端到端链路跑通
1. fork flutter-skill源码，App SDK嵌入Sleuth打点逻辑
2. 实现tap动作前后打点、采集指标并上报MCP Server
3. 实现基础MCP服务，暴露start/stop_perf_test、tap工具
4. 输出JSON报告
**交付物：最小Demo，Cursor一句话：启动测试，点击登录按钮，输出性能指标**

### Phase2：能力补齐（1~2周）
1. 补充scroll、input_text MCP工具
2. 加载阈值配置、告警逻辑
3. HTML报告生成
4. 日志优化、错误重试、页面稳定等待逻辑
**交付物：完整MCP工具集，可跑完整业务流程（登录→跳转页面→滑动列表）**

### Phase3：优化与文档（1周）
1. 稳定性优化，修复时序bug
2. README、接入文档、示例项目
3. Demo视频、使用教程
交付物：可开源发布版本，配套示例Flutter工程

## 8. 测试验收标准（V1上线准入）
1. 可以在Cursor自然语言发起测试，AI自动执行多步操作
2. 每一步操作，能采集操作前后FPS、内存，计算差值
3. 超过阈值自动生成告警，写入报告
4. 生成JSON+HTML报告，包含操作步骤、截图、性能指标
5. 示例流程：登录 -> 进入列表页 -> 滑动列表，完整跑完，无崩溃，指标正常采集
6. **统一账本**：仅手动操作（不经 MCP）也能开会话、记录点击目标、停止后得到 JSON/HTML；MCP 与手动步骤可出现在同一份报告，步骤带 `source`
7. **报告信息架构**：HTML 主视图为全会话时间线；模块（启动/页面/转场/告警）作为时间线内的段，段内嵌事件；无时间线外独立「模块大区」堆叠；JSON 含派生 `view.timeline`
8. **转场真泄漏（4.3.3 V1 + V2 多轮）**：pop 后基于资源 track/WeakRef（仍可达）产出 `transition_memory_leak`；同路由 ≥`leakConfirmRounds` 次进出存活数非递减 → `evidence=weak_ref_multi`；**不依赖强制 GC**；RSS 仅辅证；VM 深挖为 opt-in；另有 `transition_jank`

## 9. 未来迭代路线（大项规划；转场多轮确认已在 0.8.2 / §4.3.3 V2 部分落地）
1. 性能指标回归对比：对比上一版本测试指标，自动判断性能退化
2. 导出DevTools完整trace文件，和操作标记对齐
3. 支持批量用例、CI流水线集成
4. 扩展支持内存快照分析
5. 增加录制回放功能
6. 支持WebView页面测试
7. 增加AI自动性能根因分析（基于采集指标，给出优化代码建议）
8. 转场 V2 剩余 / V3：Sleuth stream 绑定、线上采样、动画窗精确帧、modal/Hero（GetX/Navigator 自动 hook 已在 0.8.3；详见 4.3.3）

## 10. 目录结构建议（项目仓库）
```
flutter-perf-agent/
├── mcp_server/          # PC端MCP服务（dart）
├── app_sdk/             # flutter-skill增强SDK（内含Sleuth打点封装）
├── example_app/         # 演示Flutter被测Demo工程
├── docs/                # 文档
├── report_template/     # HTML报告模板
└── perf_agent_config.json # 默认配置文件
```

## 11. 术语表
| 名词 | 说明 |
| ---- | ---- |
| Flutter-Perf-Agent | 本项目整体名称 |
| flutter-skill | UI操控SDK，模拟点击滑动、读取语义树 |
| Sleuth | App内嵌性能采集SDK，采集帧、内存、网络 |
| MCP Server | Model Context Protocol服务，作为Cursor和App之间的中间层 |
| 打点 | 在UI动作前后捕获性能快照，绑定操作和性能指标 |
| Profile包 | Flutter性能测试包，保留调试信息，性能数据接近线上 |
| 统一操作账本 | App SDK `SessionJournal`，MCP 与手动共用的步骤权威来源 |
| 模块段 | 时间线上的一段（启动/页面/转场/告警），内嵌该段事件；非报告底部独立分区 |
| `view.timeline` | JSON 派生字段：按时间排序的模块段列表 |
| `transitionKind` | 转场种类：push/pop/replace/modal_* / route_change |
| 转场时间窗 | T0 路由将变 → T1 落地稳定 →（pop）T2 settle，专用于转场卡顿与泄漏采样 |
| 真泄漏 | 主路径：资源 track + WeakRef/多轮仍可达；RSS 辅证；VM 深挖 opt-in |
| 三阶段 | 开发（skill+Sleuth）/ 测试（自动场景）/ 线上（轻量性能·崩溃·埋点） |

---

### 附录：示例用户指令（Cursor直接可用）
```
启动性能测试，名字：登录流程测试。
操作：
1. 找到登录按钮，点击
2. 在账号输入框输入test@test.com
3. 在密码框输入123456
4. 点击登录
等待页面跳转到首页，停止性能测试，生成报告，检查是否有卡顿、内存上涨告警。
```

---

> 直接全选复制，保存为 `prd.md` 即可。
> 如果你想，我可以再单独写一份项目 `README.md` 放在仓库根目录。需要吗？