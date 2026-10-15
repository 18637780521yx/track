# Phase2 交付说明

## 目标

补齐 MCP 工具集，可跑完整流程：**登录 → 进首页 → 滑动列表**，并输出 JSON + HTML 报告。

## 本阶段新增

| 项 | 说明 |
|----|------|
| `input_text` | flutter_skill enterText + 前后打点 |
| `scroll` | swipe（方向/距离）或 scroll_to（目标）+ 打点 |
| HTML 报告 | `reports/*.html`，步骤卡片 + 告警标红 |
| 重试 | `maxRetries` / `retryDelayMs` |
| 调试日志 | `debugLog: true` |
| 稳定等待 | Bridge `/wait` 支持多帧 + 延时 |

## 验收话术

```
启动性能测试，名字：登录到列表滑动。
1. 在密码输入框输入 123456（target: password_field）
2. 点击登录
3. 向下滑动列表两次（direction: down, distance: 400）
停止测试，给我 JSON 和 HTML 报告路径，并列出告警。
```

## 配置（perf_agent_config.json）

```json
{
  "waitStableMs": 500,
  "maxRetries": 2,
  "retryDelayMs": 300,
  "debugLog": true,
  "thresholds": {
    "maxFrameCostMs": 16,
    "memoryIncreaseWarningMB": 5,
    "slowRequestMs": 300
  }
}
```
