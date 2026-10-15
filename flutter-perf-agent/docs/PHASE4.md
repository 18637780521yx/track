# Phase4 / 0.5 — Sleuth 完整能力

## 做了什么

- App：`SleuthFacade` + Bridge `/sleuth/*`
- MCP：`get_sleuth_snapshot|issues|diagnose|summary|route_health`
- 每步附带 live issues；stop 写入完整快照进报告
- example：全量 detector + overlay

## 完整模式注意

```bash
flutter run --profile --no-dds
```

无 `--no-dds` 时 `vmConnected=false`，GC/堆/shader 等 VM 型 detector 会哑火（FrameTiming + 结构扫描仍可用）。
