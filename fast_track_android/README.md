# Fast Track Android SDK

Kotlin 埋点 SDK，协议对齐 Flutter `fast_track`。  
默认上报地址：`http://101.126.68.169:5000/track`（`FastTracker.DEFAULT_TRACK_URL`）。

- Context 由库内 `ContentProvider` 自动钩取，**`init` 不必传 context / url**
- 本地 Room 队列 + 批量 / 定时 flush + 重试
- 默认开启崩溃 / ANR 自动上报

---

## 1. 集成

### 1.1 依赖

**方式 A：自建 Maven（推荐，与 ota-sdk 同仓）**

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://ota.h10wanren.com:8443/maven/")
            content { includeGroup("com.wenrai") }
        }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("com.wenrai:fast-track:1.0.0")
}
```

发布新版本（维护者）：

```bash
cd track/fast_track_android
./scripts/publish-to-maven.sh
# → https://ota.h10wanren.com:8443/maven/com/wenrai/fast-track/
```

**方式 B：工程 module（本地联调）**

```kotlin
// settings.gradle.kts
include(":fast-track")
project(":fast-track").projectDir = file("../fast_track_android/fast-track")

// app/build.gradle.kts
dependencies {
    implementation(project(":fast-track"))
}
```

**方式 C：本地 AAR**

```kotlin
implementation(files("libs/fast-track-release.aar"))
// 另需自行带上 Room / OkHttp / coroutines / lifecycle-process 传递依赖
```

### 1.2 权限

库 Manifest 已声明 `INTERNET`、`ACCESS_NETWORK_STATE`，一般无需再写。  
Debug 访问明文 HTTP（如本机 `10.0.2.2`）时，宿主需允许 cleartext：

```xml
<application android:usesCleartextTraffic="true" ...>
```

### 1.3 最小接入

在 `Application.onCreate` 或首个 Activity 里调用一次即可（默认上报 `http://101.126.68.169:5000/track`）：

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        FastTracker.init(
            config = TrackerConfig(enableDebugLog = BuildConfig.DEBUG),
            initialCommonProperties = mapOf(
                "channel" to "official",
            ),
        )
        // 如需覆盖地址：FastTracker.init(url = "https://your.cdn/track", …)
    }
}
```

业务代码：

```kotlin
FastTracker.identify(userId)
// Activity 默认自动打 page_view；可用别名改业务名：
FastTracker.setPageAlias("MainActivity", "home")
// 同一 Activity 内的逻辑页：
FastTracker.trackPage("home_settings")
FastTracker.flush() // 可选：退后台 / 关键页时强制上报
```

默认 `TrackerConfig.autoTrackPageView = true`。关闭：`TrackerConfig(autoTrackPageView = false)`。  
另默认自动：`network_change`（网络切换）、`app_upgrade`（版本变化）。

---

## 2. API 一览

| API | 作用 |
|-----|------|
| `init(url, …)` | 初始化（幂等）；自动 `app_first_open` / `app_start`；默认自动 `page_view` / `network_change` / `app_upgrade` |
| `init(context, url, …)` | 显式传 Context（测试 / 特殊宿主） |
| `setPageAlias` / `setPageAliases` | Activity 类名 → 业务 page 名 |
| `trackPage(page, …)` | 手动 page_view（逻辑页） |
| `track(name, properties)` | 业务埋点 |
| `identify(userId)` | 绑定登录用户 `distinct_id` |
| `getAnonymousId()` | 当前匿名 ID（`ANDROID_ID`） |
| `resetIdentity()` | 登出：清 distinct、新 session；匿名 ID 仍为 `ANDROID_ID` |
| `registerCommonProperties` / `unregisterCommonProperties` | 公共属性（每条事件的 `common_properties`） |
| `setOptOut(true/false)` | 隐私退出：停止 track / flush |
| `flush()` | 立即上报队列 |
| `onForeground()` | 强制新 session + `app_foreground`（生命周期已自动调） |
| `captureException` | 非致命异常 → `app_error` |
| `captureMessage` | 自定义告警文案 → `app_error` |

---

## 3. API 用法

### `init`

```kotlin
FastTracker.init(
    // url 默认 FastTracker.DEFAULT_TRACK_URL = http://101.126.68.169:5000/track
    config = TrackerConfig(
        enableDebugLog = true,
        enableCrashReporting = true, // 默认 true
        enableAnrWatchdog = true,    // 默认 true
        anrTimeoutMs = 5_000L,
    ),
    initialCommonProperties = mapOf("channel" to "huawei"),
)
```

说明：

- 多次调用只会生效第一次
- `init` 前调用的 `track` 会进内存缓冲，init 后回放
- Context 一般不用传；测试可用 `init(context, url, …)`

### `track`

```kotlin
FastTracker.track("page_view", mapOf("page" to "home", "from" to "push"))
FastTracker.track("button_click") // properties 可省略
```

每条事件自动带上：`event_id`、`session_id`、`anonymous_id` / `distinct_id`、设备与 App 公共属性、`timestamp`。  
`anonymous_id` 优先用 `Settings.Secure.ANDROID_ID`（与公共属性 `device_udid` 同一串；读不到才生成本地 UUID）。已登录用户的画像仍以 `distinct_id` 为准。

### `identify` / `resetIdentity`

```kotlin
// 登录成功：发 identify 事件；后续事件同时带 distinct_id + anonymous_id
// 服务端会把匿名期画像合并到登录用户
FastTracker.identify("user_10086")

// 退出登录
FastTracker.resetIdentity()
```

### 公共属性

```kotlin
FastTracker.registerCommonProperties(
    mapOf(
        "vip_level" to 2,
        "ab_group" to "A",
    ),
)
FastTracker.unregisterCommonProperties(listOf("ab_group"))
```

会合并进后续事件的 `common_properties`（与 SDK 自动采集的 os / app_version 等共存）。

### `setOptOut`

```kotlin
FastTracker.setOptOut(true)  // 停止采集与上报
FastTracker.setOptOut(false) // 恢复
```

### `flush`

```kotlin
override fun onStop() {
    FastTracker.flush()
    super.onStop()
}
```

平时依赖定时（默认 15s）与满批（默认 100）自动 flush；进程切后台时 SDK 也会 flush。

### `captureException` / `captureMessage`

用于**已 catch** 或不想崩、但仍要上报的问题（事件名 `app_error`）：

```kotlin
try {
    checkout()
} catch (e: Exception) {
    FastTracker.captureException(e, mapOf("page" to "checkout", "order_id" to orderId))
    showToast("支付失败")
}

// 没有 Throwable，只记一句话
FastTracker.captureMessage("inventory empty", mapOf("sku" to skuId))
```

---

## 4. `TrackerConfig`

| 字段 | 默认 | 含义 |
|------|------|------|
| `maxBatchSize` | `100` | 每批条数；队列 ≥ 此值触发 flush |
| `flushIntervalMs` | `15000` | 定时 flush 间隔 |
| `maxCachedEvents` | `10000` | 本地队列上限，超出丢最老 |
| `maxRetryCount` | `5` | HTTP 失败重试次数 |
| `retryBackoffBaseMs` / `retryBackoffMaxMs` | `2s` / `60s` | 指数退避 |
| `retryCoolOffMs` | `30min` | 重试用尽后冷却，期间跳过 flush |
| `sessionTimeoutMs` | `30min` | Session 超时 |
| `enableDebugLog` | `false` | Logcat `FastTracker` |
| `compressRequest` | `false` | gzip body |
| `dryRun` | `false` | 只本地消费、不实际上传 |
| `environment` | 自动 | `"sandbox"` / `"production"` |
| `checkNetworkBeforeFlush` | `true` | 无网跳过本次 flush |
| `enableCrashReporting` | `true` | 未捕获崩溃 → `app_crash` |
| `enableAnrWatchdog` | `true` | 主线程堵死 → `app_anr` |
| `anrTimeoutMs` | `5000` | Watchdog 超时阈值 |

---

## 5. 自动埋点 / 稳定性

`init` 后默认行为：

| 事件 | 触发 |
|------|------|
| `app_first_open` | 本机首次 init |
| `app_start` | 每次 init |
| `app_foreground` / `app_background` | 进程前后台（`ProcessLifecycleOwner`） |
| `app_crash` | 未捕获异常；落 pending，**下次启动补报** |
| `app_anr` | 主线程超过 `anrTimeoutMs` 无响应；API 30+ 另读 `ApplicationExitInfo` |
| `app_error` | 仅 `captureException` / `captureMessage` |

关闭示例：

```kotlin
FastTracker.init(
    url = url,
    config = TrackerConfig(
        enableCrashReporting = false,
        enableAnrWatchdog = false,
    ),
)
```

> 「卡顿」此处指 **ANR（主线程堵死）**，不是 FPS / 掉帧监控。

---

## 6. 上报协议（摘要）

```json
{
  "events": [
    {
      "event_id": "uuid",
      "name": "page_view",
      "properties": { "page": "home" },
      "common_properties": { "device_os": "android", "sdk_version": "…" },
      "distinct_id": "user_10086",
      "anonymous_id": "ANDROID_ID",
      "session_id": "uuid",
      "timestamp": "2026-09-29T12:00:00.000Z"
    }
  ]
}
```

对接 Python / Go 服务：`POST /track` 或 `POST /api/v1/track`。

---

## 7. 集成 Demo（完整示例）

仓库自带 module：`demo/`（界面按钮覆盖常用 API）。

### 7.1 跑 Demo App

```bash
# 终端 1：埋点服务
cd track/track-server-py
docker compose up -d   # 或本地 python -m app.main

# 终端 2：安装 Demo
cd track/fast_track_android
./gradlew :demo:installDebug
```

- 模拟器 / 真机默认已指向线上：`http://101.126.68.169:5000/track`（`FastTracker.DEFAULT_TRACK_URL`）
- 本地调试可改成：`http://10.0.2.2:8080/track`

### 7.2 Demo 按钮对照

| 按钮 | 调用 |
|------|------|
| Init | `FastTracker.init(url, config)` |
| Track page_view | `track("page_view", …)` |
| Identify | `identify("demo_user")` |
| Flush | `flush()` |
| Capture error | `captureException(…)` |
| Crash | 主线程抛未捕获异常 → `app_crash` |
| ANR | `Thread.sleep(6000)` 堵主线程 → `app_anr` |

### 7.3 业务 App 内粘贴模板

```kotlin
package com.example.myapp

import android.app.Application
import com.fasttrack.sdk.FastTracker
import com.fasttrack.sdk.TrackerConfig

class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        FastTracker.init(
            // 默认已是线上地址；也可显式：url = FastTracker.DEFAULT_TRACK_URL
            config = TrackerConfig(
                enableDebugLog = BuildConfig.DEBUG,
                enableCrashReporting = true,
                enableAnrWatchdog = true,
                anrTimeoutMs = 5_000L,
            ),
            initialCommonProperties = mapOf(
                "channel" to "official",
            ),
        )
    }
}

// —— Activity / ViewModel ——

fun onLoginSuccess(userId: String) {
    FastTracker.identify(userId)
    FastTracker.registerCommonProperties(mapOf("is_login" to true))
    FastTracker.track("user_login", mapOf("method" to "phone"))
}

fun onPageShow(page: String) {
    FastTracker.track("page_view", mapOf("page" to page))
}

fun onLogout() {
    FastTracker.track("user_logout")
    FastTracker.unregisterCommonProperties(listOf("is_login"))
    FastTracker.resetIdentity()
    FastTracker.flush()
}

fun onCaughtError(e: Throwable, page: String) {
    FastTracker.captureException(e, mapOf("page" to page))
}
```

`AndroidManifest.xml`：

```xml
<application
    android:name=".MyApp"
    android:usesCleartextTraffic="true"
    ... >
```

---

## 8. 能力小结

- Room 本地队列（默认上限 10000）
- 15s / 满批 100 自动 flush；OkHttp 重试对齐 Flutter
- identify / session / common properties / opt-out
- 生命周期自动埋点 + 崩溃 / ANR 自动上报
- 与 `track-server-py` / `track-console` 开箱对接
