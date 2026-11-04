package com.fast_track_mcp

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native / JVM crash:
 * 1) [Thread.UncaughtExceptionHandler]（persist + try emit）
 * 2) 下次启动：pending JSON + [ApplicationExitInfo] CRASH/CRASH_NATIVE + tombstone 回捞
 */
internal class NativeCrashDetector(
    private val context: Context,
    private val onCrash: (Map<String, Any?>) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val installed = AtomicBoolean(false)
    private var previousHandler: Thread.UncaughtExceptionHandler? = null

    fun start() {
        if (!installed.compareAndSet(false, true)) return
        flushPending()
        reportHistoricalCrashes()
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            persistAndEmit(thread, throwable)
            previousHandler?.uncaughtException(thread, throwable)
        }
        Log.i(TAG, "native crash handler installed")
    }

    fun stop() {
        if (!installed.compareAndSet(true, false)) return
        Thread.setDefaultUncaughtExceptionHandler(previousHandler)
        previousHandler = null
    }

    private fun persistAndEmit(thread: Thread, throwable: Throwable) {
        val stack = throwable.stackTraceToString().take(16_384)
        val payload = mapOf(
            "event_type" to "native_crash",
            "exception_type" to (throwable.javaClass.name),
            "message" to (throwable.message ?: throwable.toString()),
            "stack" to stack,
            "thread" to (thread.name ?: "unknown"),
            "is_fatal" to true,
            "platform" to "android",
            "crash_source" to "uncaught_exception",
        )
        try {
            val json = JSONObject()
            for ((k, v) in payload) {
                json.put(k, v ?: JSONObject.NULL)
            }
            pendingFile().writeText(json.toString())
        } catch (e: Exception) {
            Log.w(TAG, "persist crash failed: $e")
        }
        mainHandler.post { onCrash(payload) }
    }

    private fun flushPending() {
        val file = pendingFile()
        if (!file.exists()) return
        try {
            val text = file.readText()
            file.delete()
            val json = JSONObject(text)
            val map = mutableMapOf<String, Any?>()
            json.keys().forEach { key -> map[key] = json.opt(key) }
            map["crash_source"] = map["crash_source"] ?: "pending_file"
            map["event_type"] = "native_crash"
            mainHandler.post { onCrash(map) }
        } catch (e: Exception) {
            Log.w(TAG, "flush pending failed: $e")
            try {
                file.delete()
            } catch (_: Exception) {
            }
        }
    }

    private fun reportHistoricalCrashes() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // API < 30：无 ExitInfo，仅尝试系统 tombstone（通常失败）
            emitTombstoneOnly()
            return
        }
        try {
            val am = context.getSystemService(ActivityManager::class.java) ?: return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val watermark = prefs.getLong(KEY_WATERMARK, 0L)
            val processHint = context.packageName
            val latest = am.getHistoricalProcessExitReasons(null, 0, 12)
                .asSequence()
                .filter {
                    (it.reason == ApplicationExitInfo.REASON_CRASH ||
                        it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) &&
                        it.timestamp > watermark
                }
                .maxByOrNull { it.timestamp }

            if (latest == null) {
                emitTombstoneOnly()
                return
            }

            val tomb = TombstoneReader.resolve(
                context = context,
                exitInfo = latest,
                processNameHint = processHint,
                allowPersistedFallback = false,
            )
            val reason = when (latest.reason) {
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "app_exit_info_native"
                else -> "app_exit_info_crash"
            }
            val stack = tomb?.text?.take(16_384)
                ?: (latest.description ?: "")
            mainHandler.post {
                onCrash(
                    buildMap {
                        put("event_type", "native_crash")
                        put("exception_type", "ApplicationExitInfo")
                        put("message", latest.description ?: reason)
                        put("stack", stack)
                        put("thread", "unknown")
                        put("is_fatal", true)
                        put("platform", "android")
                        put("crash_source", reason)
                        put("exit_timestamp_ms", latest.timestamp)
                        put("importance", latest.importance)
                        put("exit_reason", latest.reason)
                        if (tomb != null) {
                            put("tombstone", tomb.text)
                            put("tombstone_source", tomb.source)
                            if (tomb.path != null) put("tombstone_path", tomb.path)
                        }
                    },
                )
            }
            prefs.edit().putLong(KEY_WATERMARK, latest.timestamp).apply()
            TombstoneReader.clearPersistedCopy(context)
        } catch (e: Exception) {
            Log.w(TAG, "historical crash read failed: $e")
            emitTombstoneOnly()
        }
    }

    /** 无新 ExitInfo 时：尝试系统目录 tombstone（debuggable）或未消费的落盘副本。 */
    private fun emitTombstoneOnly() {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val lastTombstoneAt = prefs.getLong(KEY_TOMBSTONE_AT, 0L)
        val tomb = TombstoneReader.fromSystemDir(context.packageName)
            ?: TombstoneReader.fromPersistedCopy(context)
            ?: return
        val stamp = File(tomb.path ?: "").let { if (it.exists()) it.lastModified() else System.currentTimeMillis() }
        if (stamp > 0 && stamp <= lastTombstoneAt) return
        mainHandler.post {
            onCrash(
                mapOf(
                    "event_type" to "native_crash",
                    "exception_type" to "Tombstone",
                    "message" to "tombstone recovered (${tomb.source})",
                    "stack" to tomb.text.take(16_384),
                    "thread" to "unknown",
                    "is_fatal" to true,
                    "platform" to "android",
                    "crash_source" to "tombstone_${tomb.source}",
                    "tombstone" to tomb.text,
                    "tombstone_source" to tomb.source,
                    "tombstone_path" to tomb.path,
                ),
            )
        }
        prefs.edit().putLong(KEY_TOMBSTONE_AT, maxOf(stamp, System.currentTimeMillis())).apply()
        if (tomb.source != "persisted_tombstone") {
            TombstoneReader.persistCopy(context, tomb.text)
        } else {
            TombstoneReader.clearPersistedCopy(context)
        }
    }

    private fun pendingFile(): File =
        File(context.filesDir, "ftm_pending_native_crash.json")

    companion object {
        private const val TAG = "ftm.crash"
        private const val PREFS = "ftm_crash"
        private const val KEY_WATERMARK = "exit_info_crash_watermark_ms"
        private const val KEY_TOMBSTONE_AT = "tombstone_reported_at_ms"
    }
}
