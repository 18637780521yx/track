# Phase5 / 0.5.1 — flutter_skill 完整能力

把 flutter_skill 的 VM 扩展面完整接到 MCP（与 0.5 Sleuth 全量并列）。

## 交付

| 项 | 说明 |
|----|------|
| Client | `FlutterSkillVmClient` 覆盖全部 `ext.flutter.flutter_skill.*`（除 app 侧 `logHttpRequest`） |
| MCP | `skill_*` 工具；手势类会话内走 ActionRunner（Sleuth/RSS） |
| 快捷入口 | 保留 `tap` / `scroll` / `input_text` / `get_ui_snapshot` |

## 版本

MCP：`0.5.1`，`uiSurface: flutter_skill_full`
