# 使用教程

接入步骤见 [INTEGRATION.md](INTEGRATION.md)。事件名目录见仓库 [perf-events.md](../../doc/perf-events.md)（若存在）。

有两条日常路径：

1. **手动点 App → track-console 会话报告**（联调埋点最常用）
2. **Cursor MCP 自动化 → Bridge 报告**（回归 / 自然语言驱动）

---

## A. 埋点 + 控制台报告

### 前置

1. App 已按 INTEGRATION 接入（`FastTracker` + `FastTrackMcp`）
2. `track-server-py` 在 `:8080`
3. `track-console` 在 `:3000`
4. 真机已 `adb reverse tcp:8080 tcp:8080`

### 看报告

打开 http://localhost:3000/reports  

- 按用户聚合；登录用户显示 `identify` 后的 distinct_id  
- 时间线：页面卡 + 操作 / 网络 / 告警；离开页底部附带 `转场 kind to`  
- 裸路由 `/tabs` 会升成 `/tabs#work` 等逻辑 Tab  

### 常见问题

| 现象 | 处理 |
|------|------|
| `retry … code=null` | `adb reverse tcp:8080`；确认服务 `/health` |
| 报告「匿名」 | 登录后 / 冷启已登录调 `identify` |
| tap 挂在转场后的页 | 已修：按下时冻结路由；刷新控制台；App 需含新 SDK |
| 登录后多余 `remove` 泄漏提示 | `Get.offAll` 清栈，报告侧已忽略 |

---

## B. Cursor MCP 自动化

### 前置

1. 已接入 App SDK，且 **Debug/Profile** 下 `ensureInitialized` 成功  
2. Cursor 已配置 `fast_track_mcp`（见 INTEGRATION §5）  
3. App 在跑；Bridge 可达：

```bash
curl http://127.0.0.1:19288/health
# 真机另需：adb reverse tcp:19288 tcp:19288
```

建议：`flutter run --profile --no-dds`

### 自然语言示例

```
启动性能测试，名字：登录到列表滑动。
1. 在 password_field 输入 123456
2. 点击「登录」
3. 向下滑动列表两次
停止测试，给我报告路径并列出告警。
```

```
start_perf_test 名字：点刷新
tap 刷新按钮
stop_perf_test
```

```
启动测试「探路」
调用 get_ui_snapshot 告诉我现在有哪些可点控件
再点击登录并停止
```

### 响应信封

```json
{ "code": 0, "data": { }, "msg": "ok" }
```

`code == 0` 成功。`get_sleuth_*` 已下线（0.10）。

### 常用工具

| Tool | 说明 |
|------|------|
| `start_perf_test` / `stop_perf_test` | 开会话 / 出 JSON+HTML |
| `tap` / `input_text` / `scroll` | 可自动开会话 |
| `get_ui_snapshot` | 可交互控件 |
| `skill_call` / `skill_list_methods` | flutter_skill |
| `screenshot` | 按需截图 |

直接 `tap` / `input_text` 时：无会话会自动 start；测完仍建议显式 `stop_perf_test`。

### flutter_skill

```
启动测试「skill_full」
skill_list_methods
skill_call method=waitForElement args={text:登录}
skill_call method=longPress args={text:登录}
screenshot
停止测试
```

### 命令行 Demo

```bash
cd example_app && flutter run -d windows --profile --no-dds
# 另开
cd fast_track_mcp && ./scripts/demo.sh
```

### 报告产物（MCP 会话）

| 产物 | 内容 |
|------|------|
| `reports/*_<sessionId>.json` | 机器可读 |
| `reports/*_<sessionId>.html` | 可视化时间线 |
| `reports/screenshots/...` | 截图（若开启） |

权威账本在 App SDK；MCP 与手动操作共用。

---

## 配置调参

编辑 `perf_agent_config.json`：

| 字段 | 含义 |
|------|------|
| `bridgePort` | 默认 19288 |
| `waitStableMs` / `postActionSettleMs` | 操作后等待 |
| `captureScreenshots` | 是否截图 |
| `thresholds.*` | 告警阈值 |
| `transition.*` | 转场泄漏探针参数 |

### Release LeakOnline（可选）

不启 Bridge。按会话采样 WeakRef 转场泄漏：

```dart
await FastTrackMcp.ensureInitialized(
  leakOnlineEnabled: true,
  leakSampleRate: 0.01,
  wireLeakOnlineToFastTrack: true,
);
```

example：`flutter run --release --dart-define=LEAK_ONLINE=true`
