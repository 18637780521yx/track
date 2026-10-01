package com.fasttrack.sdk

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.room.Room
import com.fasttrack.sdk.db.TrackDatabase
import com.fasttrack.sdk.db.TrackEventEntity
import com.fasttrack.sdk.stability.AnrWatchdog
import com.fasttrack.sdk.stability.CrashReporter
import com.fasttrack.sdk.stability.ExitInfoCollector
import com.fasttrack.sdk.stability.PendingStabilityStore
import com.fasttrack.sdk.stability.StabilityPayload
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

object FastTracker {
    private const val TAG = "FastTracker"

    /** 线上默认上报地址（wanren） */
    const val DEFAULT_TRACK_URL = "http://101.126.68.169:5000/track"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val flushMutex = Mutex()
    private val initialized = AtomicBoolean(false)

    private var appContext: Context? = null
    private var config: TrackerConfig = TrackerConfig()
    private var uploader: OkHttpUploader? = null
    private var db: TrackDatabase? = null
    private var meta: MetaStore? = null
    private var pendingStore: PendingStabilityStore? = null
    private var anrWatchdog: AnrWatchdog? = null

    private val commonProperties = mutableMapOf<String, Any?>()
    private val preInitBuffer = mutableListOf<Pair<String, Map<String, Any?>>>()

    private var session: SessionInfo? = null
    private var distinctId: String? = null
    private lateinit var anonymousId: String
    private var optedOut: Boolean = false
    private var lastRetryExhaustedAtMs: Long = 0L
    private var flushJobStarted = false
    private var activityCallbacksInstalled = false
    private var networkMonitor: NetworkMonitor? = null

    /** Activity 简单类名 → page（覆盖自动命名） */
    private val pageAliases = ConcurrentHashMap<String, String>()
    private var lastAutoPage: String? = null
    private var lastAutoPageAtMs: Long = 0L

    @JvmStatic
    @JvmOverloads
    fun init(
        url: String = DEFAULT_TRACK_URL,
        headers: Map<String, String> = emptyMap(),
        config: TrackerConfig = TrackerConfig(),
        initialCommonProperties: Map<String, Any?> = emptyMap(),
    ) {
        init(
            context = AppContextHolder.require(),
            url = url,
            headers = headers,
            config = config,
            initialCommonProperties = initialCommonProperties,
        )
    }

    /**
     * 显式传入 Context（测试 / 特殊宿主）。正常应用用 [init] 无参版本即可，
     * Context 由 [FastTrackContextProvider] 自动钩取。
     * [url] 默认 [DEFAULT_TRACK_URL]。
     */
    @JvmStatic
    @JvmOverloads
    fun init(
        context: Context,
        url: String = DEFAULT_TRACK_URL,
        headers: Map<String, String> = emptyMap(),
        config: TrackerConfig = TrackerConfig(),
        initialCommonProperties: Map<String, Any?> = emptyMap(),
    ) {
        if (!initialized.compareAndSet(false, true)) {
            log("init already done, skip")
            return
        }
        AppContextHolder.install(context)
        appContext = context.applicationContext
        this.config = config
        meta = MetaStore(context)
        pendingStore = PendingStabilityStore(context.applicationContext)
        db = Room.databaseBuilder(
            context.applicationContext,
            TrackDatabase::class.java,
            "fast_track.db",
        ).build()
        uploader = OkHttpUploader(url, headers, config)

        commonProperties.clear()
        commonProperties.putAll(initialCommonProperties)
        commonProperties.putAll(AutoProperties.staticProperties(context, config.environment))

        val store = meta!!
        optedOut = store.optedOut
        anonymousId = store.anonymousId ?: UUID.randomUUID().toString().also { store.anonymousId = it }
        distinctId = store.distinctId
        session = store.loadSession()
        ensureSession(forceNew = session == null)
        store.saveCommonProperties(commonProperties)

        startFlushLoop()
        installLifecycle(context.applicationContext)
        installStability(context.applicationContext)
        installNetworkMonitor(context.applicationContext)
        replayPendingStability()

        val buffered = preInitBuffer.toList()
        preInitBuffer.clear()
        buffered.forEach { (name, props) -> track(name, props) }

        if (!store.firstOpenDone) {
            track("app_first_open")
            store.firstOpenDone = true
        }
        track("app_start")
        maybeTrackAppUpgrade(context.applicationContext, store)
        log("init done url=$url")
    }

    @JvmStatic
    @JvmOverloads
    fun track(name: String, properties: Map<String, Any?> = emptyMap()) {
        if (optedOut) return
        if (!initialized.get()) {
            synchronized(preInitBuffer) { preInitBuffer.add(name to properties) }
            return
        }
        scope.launch {
            try {
                enqueueEvent(name, properties, System.currentTimeMillis())
                val dao = db!!.eventDao()
                val count = dao.count()
                if (count >= config.maxBatchSize) {
                    flushInternal()
                }
            } catch (e: Exception) {
                log("track error: ${e.message}")
            }
        }
    }

    /** Non-fatal exception (caught errors you want to report). */
    @JvmStatic
    @JvmOverloads
    fun captureException(throwable: Throwable, extras: Map<String, Any?> = emptyMap()) {
        val props = StabilityPayload.fromThrowable(throwable, isFatal = false, extras = extras)
        track(StabilityPayload.EVENT_ERROR, props)
    }

    @JvmStatic
    @JvmOverloads
    fun captureMessage(message: String, extras: Map<String, Any?> = emptyMap()) {
        val t = RuntimeException(message)
        val props = StabilityPayload.fromThrowable(t, isFatal = false, extras = extras).toMutableMap()
        props["exception_type"] = "CaptureMessage"
        props["message"] = message
        props["fingerprint"] = com.fasttrack.sdk.stability.StackFingerprint.of(
            "CaptureMessage",
            props["stack"] as? String ?: message,
        )
        track(StabilityPayload.EVENT_ERROR, props)
    }

    @JvmStatic
    fun identify(userId: String) {
        if (userId.isBlank()) return
        val prevDistinct = distinctId
        if (prevDistinct == userId) return
        distinctId = userId
        meta?.distinctId = userId
        // 关联匿名 → 登录：后续事件仍带 anonymous_id；并打 identify 事件供服务端合并画像
        val props = linkedMapOf<String, Any?>(
            "\$user_id" to userId,
            "anonymous_id" to (if (::anonymousId.isInitialized) anonymousId else null),
        )
        if (!prevDistinct.isNullOrBlank()) {
            props["\$previous_distinct_id"] = prevDistinct
        }
        track("identify", props)
    }

    @JvmStatic
    fun resetIdentity() {
        distinctId = null
        meta?.distinctId = null
        anonymousId = UUID.randomUUID().toString()
        meta?.anonymousId = anonymousId
        ensureSession(forceNew = true)
    }

    @JvmStatic
    fun registerCommonProperties(props: Map<String, Any?>) {
        commonProperties.putAll(props)
        meta?.saveCommonProperties(commonProperties)
    }

    @JvmStatic
    fun unregisterCommonProperties(keys: Collection<String>) {
        keys.forEach { commonProperties.remove(it) }
        meta?.saveCommonProperties(commonProperties)
    }

    @JvmStatic
    fun setOptOut(optOut: Boolean) {
        optedOut = optOut
        meta?.optedOut = optOut
    }

    @JvmStatic
    fun flush() {
        scope.launch { flushInternal() }
    }

    @JvmStatic
    fun onForeground() {
        ensureSession(forceNew = true)
        track("app_foreground")
    }

    /**
     * 将 Activity 简单类名映射为业务 page 名。
     * 例：`setPageAlias("MainActivity", "player")`
     */
    @JvmStatic
    fun setPageAlias(activitySimpleName: String, page: String) {
        if (activitySimpleName.isBlank() || page.isBlank()) return
        pageAliases[activitySimpleName] = page
    }

    @JvmStatic
    fun setPageAliases(aliases: Map<String, String>) {
        aliases.forEach { (k, v) -> setPageAlias(k, v) }
    }

    /**
     * 手动 page_view（同一 Activity 内的逻辑页，如对话框 / 配对码页）。
     * 与自动埋点共用去重窗口。
     */
    @JvmStatic
    @JvmOverloads
    fun trackPage(page: String, properties: Map<String, Any?> = emptyMap()) {
        if (page.isBlank()) return
        val now = System.currentTimeMillis()
        if (page == lastAutoPage && now - lastAutoPageAtMs < 2_000L) return
        lastAutoPage = page
        lastAutoPageAtMs = now
        val props = LinkedHashMap<String, Any?>()
        props["page"] = page
        props["auto"] = false
        props.putAll(properties)
        track("page_view", props)
    }

    private fun installStability(context: Context) {
        if (config.enableCrashReporting) {
            CrashReporter(pendingStore!!) { name, props ->
                // Best-effort enqueue + flush before process dies
                try {
                    runBlocking {
                        withTimeoutOrNull(800) {
                            enqueueEvent(name, props, System.currentTimeMillis())
                            flushInternal()
                        }
                    }
                } catch (_: Exception) {
                }
            }.install()
        }
        if (config.enableAnrWatchdog) {
            anrWatchdog = AnrWatchdog(config.anrTimeoutMs) { blockedMs, stack ->
                track(
                    StabilityPayload.EVENT_ANR,
                    StabilityPayload.anr(blockedMs, "watchdog", stack),
                )
            }.also { it.start() }
        }
        ExitInfoCollector(
            context = context,
            getLastTs = { meta?.lastExitInfoTs ?: 0L },
            setLastTs = { meta?.lastExitInfoTs = it },
            onAnr = { desc, stack ->
                track(
                    StabilityPayload.EVENT_ANR,
                    StabilityPayload.anr(0L, "exit_info", stack, mapOf("description" to desc)),
                )
            },
        ).collectIfNeeded()
    }

    private fun replayPendingStability() {
        val store = pendingStore ?: return
        val items = store.loadAll()
        if (items.isEmpty()) return
        scope.launch {
            for (item in items) {
                try {
                    enqueueEvent(item.name, item.properties, item.timestampMs)
                    item.file.delete()
                } catch (e: Exception) {
                    log("replay pending failed: ${e.message}")
                }
            }
            flushInternal()
        }
    }

    private suspend fun enqueueEvent(name: String, properties: Map<String, Any?>, timestampMs: Long) {
        ensureSession(forceNew = false)
        val mergedCommon = LinkedHashMap<String, Any?>()
        mergedCommon.putAll(commonProperties)
        mergedCommon.putAll(AutoProperties.dynamicProperties(appContext))
        val entity = TrackEventEntity(
            eventId = UUID.randomUUID().toString(),
            name = name,
            propertiesJson = JSONObject(properties).toString(),
            commonPropertiesJson = JSONObject(mergedCommon).toString(),
            distinctId = distinctId,
            anonymousId = anonymousId,
            sessionId = session!!.id,
            timestampMs = timestampMs,
        )
        val dao = db!!.eventDao()
        dao.insert(entity)
        val count = dao.count()
        if (count > config.maxCachedEvents) {
            dao.deleteOldest(count - config.maxCachedEvents)
        }
    }

    private fun installNetworkMonitor(context: Context) {
        if (!config.autoTrackNetworkChange) return
        if (networkMonitor != null) return
        networkMonitor = NetworkMonitor(context) { from, to ->
            track(
                "network_change",
                mapOf(
                    "from" to from,
                    "to" to to,
                ),
            )
        }.also { it.start() }
    }

    private fun maybeTrackAppUpgrade(context: Context, store: MetaStore) {
        if (!config.autoTrackAppUpgrade) return
        val version = commonProperties["app_version"]?.toString().orEmpty()
        val build = commonProperties["app_build"]?.toString().orEmpty()
        if (version.isEmpty() && build.isEmpty()) return
        val prevVersion = store.lastAppVersion
        val prevBuild = store.lastAppBuild
        if (prevVersion != null || prevBuild != null) {
            if (prevVersion != version || prevBuild != build) {
                track(
                    "app_upgrade",
                    mapOf(
                        "from_version" to (prevVersion ?: ""),
                        "to_version" to version,
                        "from_build" to (prevBuild ?: ""),
                        "to_build" to build,
                    ),
                )
            }
        }
        store.lastAppVersion = version
        store.lastAppBuild = build
    }

    private fun installLifecycle(context: Context) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    onForeground()
                }

                override fun onStop(owner: LifecycleOwner) {
                    track("app_background")
                    flush()
                }
            })
        }
        if (config.autoTrackPageView) {
            installActivityPageTracking(context)
        }
    }

    private fun installActivityPageTracking(context: Context) {
        if (activityCallbacksInstalled) return
        val app = context.applicationContext as? Application ?: return
        activityCallbacksInstalled = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                maybeAutoTrackPage(activity)
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    private fun maybeAutoTrackPage(activity: Activity) {
        val simple = activity.javaClass.simpleName
        if (simple in config.autoTrackPageIgnore) return
        val page = pageAliases[simple] ?: defaultPageName(simple)
        if (page.isBlank()) return
        val now = System.currentTimeMillis()
        if (page == lastAutoPage && now - lastAutoPageAtMs < 2_000L) return
        lastAutoPage = page
        lastAutoPageAtMs = now
        track(
            "page_view",
            mapOf(
                "page" to page,
                "auto" to true,
                "activity" to simple,
            ),
        )
    }

    /** MainActivity → main；ScreenCapturePermissionActivity → screen_capture_permission */
    private fun defaultPageName(simpleName: String): String {
        val base = simpleName.removeSuffix("Activity")
        if (base.isEmpty()) return simpleName.lowercase()
        return base
            .replace(Regex("([a-z0-9])([A-Z])"), "$1_$2")
            .replace(Regex("([A-Z]+)([A-Z][a-z])"), "$1_$2")
            .lowercase()
    }

    private fun startFlushLoop() {
        if (flushJobStarted) return
        flushJobStarted = true
        scope.launch {
            while (isActive) {
                delay(config.flushIntervalMs)
                flushInternal()
            }
        }
    }

    private suspend fun flushInternal() {
        if (optedOut) return
        val uploader = uploader ?: return
        val dao = db?.eventDao() ?: return

        if (lastRetryExhaustedAtMs > 0 &&
            System.currentTimeMillis() - lastRetryExhaustedAtMs < config.retryCoolOffMs
        ) {
            return
        }

        if (config.checkNetworkBeforeFlush && !isOnline()) {
            log("skip flush: offline")
            return
        }

        flushMutex.withLock {
            while (true) {
                val remaining = dao.count()
                if (remaining == 0) break
                val batchSize = minOf(config.maxBatchSize, remaining)
                val events = dao.loadOldest(batchSize)
                if (events.isEmpty()) break

                val result = uploader.upload(events)
                val ids = events.map { it.eventId }
                when {
                    result.success -> {
                        dao.deleteByIds(ids)
                        lastRetryExhaustedAtMs = 0L
                    }
                    !result.shouldRetry -> {
                        dao.deleteByIds(ids)
                        log("drop batch permanent: ${result.error}")
                    }
                    else -> {
                        lastRetryExhaustedAtMs = System.currentTimeMillis()
                        log("retry cool-off: ${result.error}")
                        break
                    }
                }
            }
        }
    }

    private fun ensureSession(forceNew: Boolean) {
        val now = System.currentTimeMillis()
        val current = session
        val expired = current == null ||
            forceNew ||
            now - current.lastActiveAtMs > config.sessionTimeoutMs
        val next = if (expired || current == null) {
            SessionInfo(
                id = UUID.randomUUID().toString(),
                startedAtMs = now,
                lastActiveAtMs = now,
            )
        } else {
            current.copy(lastActiveAtMs = now)
        }
        session = next
        meta?.saveSession(next)
    }

    private fun isOnline(): Boolean {
        val ctx = appContext ?: return true
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun log(msg: String) {
        if (config.enableDebugLog) {
            Log.d(TAG, msg)
        }
    }
}
