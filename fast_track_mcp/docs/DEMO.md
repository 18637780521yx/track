# Demo 脚本（代替录屏说明）

本仓库用可复现脚本代替 Demo 视频，保证任何人本地能跑出同样结果。

## 60 秒演示

```bash
# 1) 启动 Demo App（另开终端）
cd example_app
flutter run -d macos --debug

# 2) 一键冒烟 + 打开 HTML
cd ..
chmod +x scripts/demo.sh
./scripts/demo.sh
```

预期终端末尾出现 `DEMO_OK` / `SMOKE_OK`，并打开 HTML 报告。

## 演示流程对应 PRD 验收

| PRD 要求 | Demo 体现 |
|----------|-----------|
| 自然语言 / 自动化多步 | MCP 工具或 `e2e_smoke.dart` |
| 每步前后性能 diff | JSON/HTML 步骤卡片 |
| 超阈值告警 | 告警区（debug 内存涨幅可能触发） |
| JSON + HTML + 截图 | `reports/` |
| 登录 → 列表 → 滑动 | smoke 固定四步 |

## Cursor 演示话术

见 [USAGE.md](USAGE.md)。
