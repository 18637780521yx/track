## 0.2.2

- Add build-mode defaults for the upload URL and a useReleaseUrl override.

## 0.2.1

- Improve batched telemetry, durable crash persistence, and manual network reporting.

## 0.2.0

- **Track-only**：移除 App 内 Crash/ANR/Jank/Memory 检测与 `NavigatorObserver`；钩子归 `fast_track_mcp` App SDK，本包只负责 `FastTracker` 上报管道。
- `init` 零钩子：无 CrashHandler、无生命周期/路由自动埋点；检测请接 `fast_track_mcp`。

## 0.1.0

- Published as flutter_fast_track.

- Initial release: session, batching, retry, ObjectBox persistence, auto properties, and pluggable upload.
