## 0.10.3

- Honor enableHttpCapture in release builds and retain bodies only for failed requests in release.

## 0.10.2

- Fix request.done closing HTTP requests before the request body is sent.
- Preserve one shared captured response for close() and done, including HTTP error bodies.
- Require protocol 0.10.1 for network business outcome fields.

## 0.10.1

- Add layered memory evidence, rolling frame-budget jank detection, accurate startup timings, and opt-in successful HTTP body capture.

## 0.10.0

- First pub.dev release of the Fast Track MCP App SDK.
- Detect: Crash / ANR / jank / memory（无 Sleuth）；事件经 `flutter_fast_track` 上报。
- Bridge `:19288`、手势 / 转场账本、HTTP 抓包、原生 Crash / Tombstone / App Hang。
- 依赖 `flutter_fast_track ^0.2.0`、`fast_track_mcp_protocol ^0.10.0`。
