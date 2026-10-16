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

### flutter_skill 完整能力（0.5.1+）

常用仍用 `tap` / `input_text` / `scroll`；其余走 `skill_*`：

```
启动测试「skill_full」
skill_interactive / skill_get_widget_tree
skill_wait_for_element（text=登录）
skill_long_press / skill_double_tap / skill_go_back
skill_screenshot / skill_get_logs
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
| `reports/*.json` | 机器可读：步骤、diff、告警、截图路径 |
| `reports/*.html` | 可视化：步骤卡片、告警标红、截图嵌入 |
| `reports/screenshots/<session>/` | 每步 PNG |

## 配置调参

编辑 `perf_agent_config.json`：

| 字段 | 含义 |
|------|------|
| `waitStableMs` | 操作后 Bridge 等待 |
| `postActionSettleMs` | 额外 settle |
| `navigationWaitMs` | 登录类点击后的跳转等待 |
| `maxRetries` | flutter_skill 重试次数 |
| `captureScreenshots` | 是否截图 |
| `thresholds.*` | 告警阈值 |
