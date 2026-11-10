package com.fast_track_mcp

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Native ANR:
 * 1) Main-looper heartbeat watchdog (real-time soft/hard hang)
 * 2) ApplicationExitInfo REASON_ANR on API 30+ (next-launch post-mortem)
 */
internal class AnrDetector(
    private val context: Context,
    private val onAnr: (Map<String, Any?>) -> Unit,
) {
    private val pendingStore = PendingAnrStore(context)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private val pingId = AtomicLong(0)
    private val ackedId = AtomicLong(0)
    private var watchdogThread: Thread? = null
    private var timeoutMs: Long = 5_000
    private var lastReportAtMs: Long = 0

    fun start(timeoutMs: Long) {
        if (!running.compareAndSet(false, true)) { replayPending(); return }
        this.timeoutMs = timeoutMs.coerceAtLeast(1_000)
        reportHistoricalAnrs()
        replayPending()
        val thread = Thread({
            Log.i(TAG, "watchdog started timeout=${this.timeoutMs}ms")
            while (running.get()) {
                val id = pingId.incrementAndGet()
                mainHandler.post {
                    ackedId.set(id)
                }
                try {
                    Thread.sleep(this.timeoutMs)
                } catch (_: InterruptedException) {
                    break
                }
                if (!running.get()) break
                if (ackedId.get() >= id) continue

                val stack = Looper.getMainLooper().thread.stackTrace
                    .joinToString("\n") { it.toString() }
                emit(
                    mapOf(
                        "blocked_ms" to this.timeoutMs,
                        "anr_source" to "android_watchdog",
                        "stack" to stack,
                        "is_fatal" to false,
                        "platform" to "android",
                    ),
                )
            }
        }, "ftm-anr-watchdog")
        thread.isDaemon = true
        watchdogThread = thread
        thread.start()
    }

    fun stop() {
        running.set(false)
        watchdogThread?.interrupt()
        watchdogThread = null
    }

    private fun emit(payload: Map<String, Any?>) {
        val now = System.currentTimeMillis()
        val cooldown = timeoutMs * 3
        if (now - lastReportAtMs < cooldown) return
        lastReportAtMs = now
        // Channel invoke must happen on main; queue even if blocked — delivered after recover.
        mainHandler.post { onAnr(payload) }
    }

    private fun reportHistoricalAnrs() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val am = context.getSystemService(ActivityManager::class.java) ?: return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val watermark = prefs.getLong(KEY_WATERMARK, 0L)
            val history = am.getHistoricalProcessExitReasons(null, 0, 32)
                .filter { it.reason == ApplicationExitInfo.REASON_ANR && it.timestamp > watermark }
                .sortedBy { it.timestamp }
            for (latest in history) {
            val id = "anr-${latest.timestamp}-${latest.pid}"
            if (pendingStore.isAcknowledged(id)) continue
            val tomb = TombstoneReader.resolve(
                context = context,
                exitInfo = latest,
                processNameHint = context.packageName,
            )
            val trace = tomb?.text ?: ""
            // Bypass watchdog cooldown — post-mortem is once per exit.
            pendingStore.put(id,
                    buildMap {
                        put("anr_id", id)
                        put("event_type", "anr")
                        put("blocked_ms", timeoutMs)
                        put("anr_source", "app_exit_info")
                        put("stack", trace.take(16_384))
                        put("is_fatal", true)
                        put("platform", "android")
                        put("exit_timestamp_ms", latest.timestamp)
                        put("importance", latest.importance)
                        put("description", latest.description ?: "")
                        if (tomb != null) {
                            put("tombstone", tomb.text)
                            put("tombstone_source", tomb.source)
                            if (tomb.path != null) put("tombstone_path", tomb.path)
                        }
                    },
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "historical ANR read failed: $e")
        }
    }

    fun replayPending() {
        if (!running.get()) return
        pendingStore.readPending().forEach { record ->
            val id = record["anr_id"] as? String ?: return@forEach
            if (!pendingStore.isAcknowledged(id)) mainHandler.post { onAnr(record) }
        }
    }

    fun acknowledge(id: String) = pendingStore.acknowledge(id)

    companion object {
        private const val TAG = "ftm.anr"
        private const val PREFS = "ftm_anr"
        private const val KEY_WATERMARK = "exit_info_watermark_ms"
    }
}
