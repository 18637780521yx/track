# Phase3 交付说明

## 目标

稳定性优化 + 文档/教程，形成可开源的 V1。

## 本阶段改动

| 项 | 说明 |
|----|------|
| 复用 VM 连接 | 会话内单例 `FlutterSkillVmClient`，避免每步重连 |
| 开会话前 stop | 清理残留 Bridge session |
| 导航等待 | 登录类 tap 额外 `navigationWaitMs` |
| 操作 settle | `postActionSettleMs` |
| 步骤截图 | flutter_skill screenshot → PNG + HTML 嵌入 |
| 文档 | INTEGRATION / USAGE / DEMO / CHANGELOG |
| Demo 脚本 | `scripts/demo.sh` |

## 版本

MCP / 报告：`0.3.0`，`schemaVersion: 3`，`phase: phase3`
