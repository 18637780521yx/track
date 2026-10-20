# 使用教程

## 前置

1. 已接入 `PerfAgent` + `Sleuth`（见 [INTEGRATION.md](INTEGRATION.md)）
2. Cursor 已配置 `flutter-perf-agent` MCP
3. App 正在跑（建议 `--profile`）

```bash
# 完整 Sleuth（含 GC/堆等）：务必 --no-dds
cd example_app && flutter run -d macos --profile --no-dds
curl http://127.0.0.1:19288/health
curl http://127.0.0.1:19288/sleuth/diagnose
```

## Cursor 自然语言示例

### 完整登录 → 滑动

```
启动性能测试，名字：登录到列表滑动。
1. 在 password_field 输入 123456
2. 点击「登录」
3. 向下滑动列表两次，distance 400
停止测试，给我 JSON 和 HTML 报告路径，并列出告警。
```

### 只点一个按钮看性能

```
start_perf_test 名字：点刷新
tap 刷新按钮
stop_perf_test
```

### 先看页面再操作

```
启动测试「探路」
调用 get_ui_snapshot 告诉我现在有哪些可点控件
再点击登录按钮并停止，输出报告
```

### Sleuth 完整能力（0.5）

```
启动测试「sleuth_full」
get_sleuth_diagnose   # 确认 vmConnected
在 password_field 输入 123456，点登录，向下滑
get_sleuth_issues
get_sleuth_summary
get_sleuth_route_health
停止测试并给出报告路径
```

### 响应信封（0.6）

所有 Bridge HTTP 与 MCP tool JSON：

```json
{ "code": 0, "data": { }, "msg": "ok" }
```

`code == 0` 成功；非 0 见 `ApiCodes`（400 / 503 / 1001 无会话 / 1002 skill / 1003 sleuth / 1004 动作失败）。

### 自动性能（0.6.2）

直接 `tap` / `input_text` / `scroll` / `skill_call`（手势）即可：

1. 无会话时自动 `start`
2. 每步前后采 Sleuth/RSS，写告警
3. 覆盖更新 `reports/live_<sessionId>.json` / `.html`
4. 测完调用 `stop_perf_test` 拿最终报告

不必再先手动 `start_perf_test`（仍可显式调用）。

### 统一账本：MCP + 手动（0.7.0）

报告权威在 **App SDK**（`SessionJournal`），MCP 与手动共用：

| 来源 | 怎么记步骤 | 怎么出报告 |
|------|------------|------------|
| MCP | 每步全量 upsert 路由章到 App SDK 账本 | `stop_perf_test` → **仅** `app_sdk` HTML（与手动同款） |
| 手动 | 点击 hitTest（key/文案/hint） | App 顶栏「结束」或 Bridge `POST /session/stop` |

手动用法：跑 `example_app`（debug/profile）→ 直接点界面（首次点击可自动开会话）→ 点顶栏 **结束** → 看 `reports/*_<sessionId>.json` / `.html`。步骤带 `source=mcp|manual`。  
MCP 不再另写一份大 HTML；`live_<sessionId>.html` 也由 SDK 账本刷新。

### flutter_skill（skill_call）

常用仍用 `tap` / `input_text` / `scroll`；其余：

```
启动测试「skill_full」
skill_list_methods
skill_call method=interactive
skill_call method=waitForElement args={text:登录}
skill_call method=longPress args={text:登录}
skill_screenshot
get_sleuth_issues
停止测试
```

### 导出会话快照

```
启动测试「snapshot_demo」
…操作…
停止测试并 export_session_snapshot
```

## 不用 Cursor：命令行 Demo

```bash
# 终端1：跑 App
cd example_app && flutter run -d macos --debug

# 终端2：
cd flutter-perf-agent
./scripts/demo.sh
```

会跑通 `input_text → tap → scroll ×2`，并尝试打开最新 HTML 报告。

## 报告里有什么

| 产物 | 内容 |
|------|------|
| `reports/*.json` | 机器可读：`steps`/`alerts` + 派生 `view`（`timeline` 模块段 + `events`） |
| `reports/*.html` | 可视化：时间线内嵌模块段（启动/页面/转场/告警），段内是事件 |
| `reports/screenshots/<session>/` | 每步 PNG |

HTML 结构（schemaVersion 9）：

1. **摘要**：耗时、步骤、告警、网络、FPS/RSS
2. **全会话时间线**：按时间的模块段；每段内嵌事件（截图/操作/网络/跳转等）；chips 按模块筛选
3. **环境与阈值**：阈值 + Sleuth diagnose

## 配置调参

编辑 `perf_agent_config.json`（MCP）：

| 字段 | 含义 |
|------|------|
| `waitStableMs` | 操作后 Bridge 等待 |
| `postActionSettleMs` | 额外 settle |
| `navigationWaitMs` | 登录类点击后的跳转等待 |
| `maxRetries` | flutter_skill 重试次数 |
| `captureScreenshots` | 是否截图 |
| `thresholds.*` | 告警阈值 |

转场泄漏（App SDK `ensureInitialized` **或** MCP `perf_agent_config.json` → `transition`，开会话下推）：

| 字段 | 含义 | 默认 |
|------|------|------|
| `leakTrackEnabled` | WeakRef 转场泄漏探针 | `true` |
| `transitionSettleMs` | pop 后 settle 再检 WeakRef | `1500` |
| `leakConfirmRounds` | 连续进出确认轮数（阶梯/持平） | `2` |
| `leakRssRetainMb` | RSS 辅证阈值（MB） | `5` |

```json
"transition": {
  "leakTrackEnabled": true,
  "transitionSettleMs": 1500,
  "leakConfirmRounds": 2,
  "leakRssRetainMb": 5,
  "sleuthBindEnabled": true
}
```

Sleuth 转场绑定（0.8.6）：push 时记录 issue 指纹，pop 后若新增 `heap_growing` / `stream_resource_growth` / `native_memory_growing`，写入探针 `sleuthHits`，`evidence` 可为 `sleuth` 或与 WeakRef 组合。需探测器实际 hit（常要 `--profile`）才会非空。

手动验收多轮：「我的」Tab →「打开独立个人页（泄漏多轮演示）」→ 返回 → 再打开再返回；第二次 pop 后 HTML 转场段应出现「多轮确认」与 `weak_ref_multi`（`ProfilePushController.demoRetain` 故意握持；登记由 `PerfDi.lazyPut` 自动完成）。

告警可读性（0.8.4）：HTML 告警块会展开 `value`（如新增 Sleuth issue 的 title）；同一步多点击时 `memory_increase` 与步骤 `diff.memoryDeltaMb` 同源（章起点 RSS），不再出现「告警涨、diff 跌」打架。

### GetX / Navigator 自动 hook（0.8.3）

```dart
GetMaterialApp(
  getPages: PerfAgent.instrumentGetPages(AppPages.routes),
  navigatorObservers: PerfAgent.navigatorObservers,
);

// Binding 内（推荐）
PerfDi.lazyPut(MyController.new);

// 或 Controller：with PerfLeakTrackMixin / extends PerfGetxController
```
