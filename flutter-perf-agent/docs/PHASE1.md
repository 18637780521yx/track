# Phase1 交付说明

## 目标

端到端打通：Cursor → MCP → flutter_skill（UI）+ PerfBridge（打点）→ JSON 报告。

## 架构（已对齐 PRD）

```
Cursor
  └─ flutter-perf-agent MCP
        ├─ UI：flutter_skill VM 扩展（tap / inspect）
        └─ 性能：HTTP PerfBridge（session / snapshot / wait）
              └─ Sleuth + RSS
```

| 能力 | 负责方 |
|------|--------|
| 点击 / 读 UI | **flutter_skill** |
| 会话、前后快照、等待稳定 | **app_sdk Bridge** |
| 编排、diff、告警、JSON 报告 | **mcp_server** |
| `UiActions` / Bridge `/tap` | **legacy 回退**（flutter_skill 失败时） |

## 已实现

1. `app_sdk`：`PerfAgent` + Sleuth 快照 + Bridge（含 `vmServiceUri`）
2. `mcp_server`：`start_perf_test` / `tap`（优先 flutter_skill）/ `stop_perf_test` / `get_ui_snapshot`
3. `example_app`：登录 Demo（Semantics + Key）
4. 阈值告警写入报告

## 验收话术

```
启动性能测试，名字：登录流程测试。
用 flutter_skill 点击「登录」。
停止性能测试，生成报告，告诉我报告路径和是否有告警。
```

## 未做（Phase2+）

- scroll / input_text MCP 工具（同样走 flutter_skill）
- HTML 报告与截图嵌入
- Android 模拟器端口转发一键脚本
