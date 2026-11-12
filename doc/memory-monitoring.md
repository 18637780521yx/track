# 内存检测与证据分级

## 已实现

检测思路参考 Sleuth 0.37 / 1.0 的窗口趋势、GC 后堆底线、资源数量和异常 episode，使用本项目的采集与上报链路，不重新引入 Sleuth 的全局控制器或网络钩子。许可声明见 [THIRD_PARTY_NOTICES.md](../fast_track_mcp/app_sdk/THIRD_PARTY_NOTICES.md)。

### Release：轻量 RSS

- 默认每 30 秒采集进程 RSS。首次有效样本后预热 30 秒；以真实采样时间计算滑动窗口最小二乘回归。
- 默认至少 6 个样本、跨度 150 秒，增长速率超过约 68.3 KiB/s，且持续 30 秒后报告 `memory_growth`。允许 GC 锯齿，不要求每个点递增；窗口后半段也必须增长，排除旧尖峰后的平台。
- 默认预算 512 MiB，仅是可调整的初始值，不是通用故障线。最近 5 个有效间隔样本中至少 4 个超预算才报告 `memory_pressure`。恢复至预算 90% 以下 4/5 次才结束同一次超预算 episode。
- `memoryPressureBytes: 0` 可关闭预算检查，趋势检测保持启用。设备档位与业务预算由宿主选择，SDK 不假设所有设备一致。

### Debug / Profile：VM 证据

默认启用 `enableVmMemoryMonitoring`。只连接当前 isolate 的现有 VM Service；无法连接或 RPC 超时会退回 RSS。Release 从不启动 VM 采集。

| 类型 | 来源 | 判断含义 |
| --- | --- | --- |
| `heap_growing` | 每 5 秒读取 Dart 堆，窗口回归并持续增长 | Dart 堆增长趋势，`likely` |
| `gc_pressure` | 当前 isolate 的 GC 事件，10 秒窗口超过 30 次 | 回收频繁，不等于暂停严重或泄漏 |
| `heap_retained_growth` | 预热后 idle 完整 GC 的 `new.used + old.used`，至少 3 次、跨度 10 秒 | 回收后堆底线抬高，`strong`，仍需解释存活对象的用途 |
| `native_memory_growing` | RSS − 当前 isolate Dart 堆 − external 的窗口趋势 | RSS 残差估算，包含其他 isolate、共享页和分配器保留空间，不能确认原生泄漏 |
| `stream_resource_growth` | 每 30 秒获取 allocation profile，对核实为 `dart:async` 的 StreamController、StreamSubscription、Timer 类观察数量 | 至少 4 个样本、跨度 60 秒且增加至少 3 个实例，并有最近 30 秒内的堆增长佐证，才提示疑似资源累积 |

堆和残差默认预热 30 秒；至少 4 个点、跨度 10 秒，分别超过 500 KiB/s、1 MiB/s 并持续 10 秒。GC 后堆底线仅接受新鲜、能归属当前 isolate 的 idle `MarkSweep` / `MarkCompact`，或紧接 idle 并发标记的完整回收；缺失和非 idle 回收不会伪造证据。

VM 自动采集不强制 GC，不抓完整堆快照。allocation profile 中前 8 个类按存活字节排序展示，供排查方向参考，并不是这些类已泄漏。资源库元数据缺失时通过有数量限制的 Class 查询核实，无法核实时该轮记为未知。

### 事件与报告

为兼容已部署服务，仍使用 `app_memory_leak` 事件名；具体含义以 `properties.type` 为准。

- 携带 `detector_version=2`、`evidence`、`confidence`、`observation_scope`、稳定的 `episode_id`、窗口样本和增长速率。
- 所有自动趋势判断都携带 `leak_confirmed=false`。`gc_verified=true` 只表示使用了符合条件的 GC 后观测，**不表示某个页面对象已确认泄漏**。
- 同一检测器 / 资源 / episode 最多每 5 分钟上报一次，恢复后新的 episode 可以立即上报；预算告警不被正在上报的增长事件阻塞。
- 报告按页面观测段、类型、资源和 episode 合并；旧数据无 episode 时仅合并相距不超过 10 分钟的同类观测。保留首次 / 末次时间、观测跨度、峰值 RSS、最新证据；会话原始事件仍保留。
- RSS 总量和窗口增长量分别显示。趋势与预算提示使用黄色，不再把所有内存线索当红色泄漏。
- 会话顶部只展示该会话事件中实际观测到的 RSS 峰值，不把进程整个生命周期的 `max_rss_mb` 冒充本会话峰值。
- RSS 与 isolate 级 VM 观测保留在观测发生页，页面仅是上下文，不表示页面是根因；明确的转场 WeakRef 证据才归属刚退出的页面。

## 接入

```dart
await FastTrackMcp.ensureInitialized(
  memoryPressureBytes: 384 * 1024 * 1024, // 示例，请按设备与业务验证
  enableVmMemoryMonitoring: true, // Debug/Profile 生效；Release 始终禁用
);
```

低层 `FastTrackMcpMemoryMonitor.start` 还可配置 RSS 的预热、增长持续时间、采样周期和增长速率预算（通过兼容参数 `minGrowthBytes / sampleInterval` 换算）。

## 定位边界

这套方案提供分层证据和分配热点，尚不自动生成 GC Root 引用链或跨平台原生分配调用栈。确认根因仍需 DevTools 堆快照对比 / retaining path，或对应平台的原生内存工具。原有页面 WeakRef 多轮检查继续作为独立证据，不因 RSS 或堆增长自动升级为确认泄漏。

验证覆盖启动加载后平台、锯齿回收、非均匀采样、采样间断、预算抖动与恢复、GC 类型过滤、资源消失、不同 episode 隔离、报告归属及重复事件 ID。
