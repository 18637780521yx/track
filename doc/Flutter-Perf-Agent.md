# PRD：Flutter AI性能测试Agent
> 项目代号：Flutter-Perf-Agent
版本：V1.0
编写日期：2026-10-15
目标：基于 flutter-skill + Sleuth，搭建一套**大模型驱动Flutter应用自动化UI操作+性能采集**的本地测试工具，对标鸿蒙oh-flutter的AI测试能力。
一句话目标：用户在Cursor用自然语言指挥AI操作Flutter App，自动采集每一步操作对应的性能指标，输出带性能指标、截图、告警的测试报告。

## 1. 产品概述
### 1.1 背景
现有Flutter生态缺少开源的「大模型自主探索UI自动化 + 内嵌性能采集」一体化工具。
传统自动化工具依赖固定脚本；DevTools只能人工手动录制trace，无法和UI动作时序自动对齐。
本项目将 **flutter-skill（MCP UI操控SDK）** 和 **Sleuth（App内嵌性能采集SDK）** 组合，实现：LLM自然语言驱动App交互，每一步动作自动打点采集性能，自动生成性能测试报告。

### 1.2 产品目标
- 支持自然语言指令驱动Flutter Debug/Profile包，自动点击、滑动、输入文本、弹窗处理
- 在每一次UI操作前后自动采集性能指标（FPS、卡顿Jank、内存、慢网络、Widget反模式告警）
- MCP协议接入Cursor，用户一句话发起测试，AI自主完成流程+性能采集+结果汇总
- 输出结构化测试报告：操作步骤、截图、性能指标、性能告警、指标对比

### 1.3 非目标（V1不做）
1. 不支持Release包（仅Debug / Profile）
2. 不支持跨App操作，只测当前被测Flutter应用
3. 不做线上APM、不做云端部署，**本地单机工具**
4. V1不支持多设备并发测试
5. 不做完整堆快照 Diff 图形化；V1 指标以 Sleuth + RSS 为准
6. 不支持iOS真机深度无障碍（优先Android模拟器/本地桌面Flutter）
7. 本期不做 App Size / Deep links
8. 不外连 DevTools 采 Timeline/CPU/Heap；VM 仅用于 flutter_skill UI
9. 不嵌 DevTools Web UI

## 2. 用户角色
**目标用户：Flutter开发者 / 移动端测试工程师**
- 使用Cursor + MCP，自然语言发起App自动化性能测试
- 不需要手写测试脚本，直接用自然语言描述测试流程
- 在开发阶段做回归测试、卡顿检测、内存增长检查

## 3. 核心架构
```
Cursor(LLM Client) ←MCP(stdio JSON-RPC)→ Flutter-Perf-Agent MCP Server
                                                ↓指令下发
                                  flutter-skill App SDK（App内，负责点击/滑动）
                                                ↓动作打点
                                  Sleuth SDK（App内嵌，性能采集：FPS/Jank/内存/网络）
                                                ↓指标回传
                                  MCP Server汇总：操作日志 + 截图 + 性能数据 → 生成报告
```

### 模块清单
1. **MCP Server模块（PC端，dart）**
    - 对外暴露MCP工具给Cursor
    - 管理和App端flutter-skill SDK的通信
    - 接收App上报的操作日志、截图、Sleuth性能指标
    - 报告生成、JSON持久化
2. **App SDK模块（嵌入被测Flutter App，dev依赖）**
    - flutter-skill：语义树读取、Pointer手势注入（点击/滑动/输入）
    - Sleuth：帧时序、卡顿、内存、网络、Widget反模式采集
    - 打点增强层：在tap/scroll/input动作**执行前、执行后**采集Sleuth指标，计算指标差值
3. **报告模块**：生成JSON/HTML报告

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
输出2种产物：
1. JSON原始报告：机器可读，用于CI对比回归
    - 测试元信息：测试名称、开始结束时间、profile/debug模式
    - 操作步骤数组：每一步动作描述、前后性能快照、指标差值、截图路径
    - 告警列表：超过阈值的性能问题
2. HTML可视化报告（可读）
    - 步骤时序图，每一步附带性能卡片
    - 告警标红展示
    - 截图嵌入报告

### 4.4 配置能力
支持配置文件 `perf_agent_config.json`
- 性能告警阈值：
  - maxFrameCostMs：单帧最大耗时阈值（默认16ms）
  - memoryIncreaseWarningMB：单次内存上涨告警阈值（默认5MB）
  - slowRequestMs：慢接口阈值（默认300ms）
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

## 9. 未来迭代路线（V2规划，本次不实现）
1. 性能指标回归对比：对比上一版本测试指标，自动判断性能退化
2. 导出DevTools完整trace文件，和操作标记对齐
3. 支持批量用例、CI流水线集成
4. 扩展支持内存快照分析
5. 增加录制回放功能
6. 支持WebView页面测试
7. 增加AI自动性能根因分析（基于采集指标，给出优化代码建议）

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