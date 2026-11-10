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
import java.io.FileOutputStream
import java.util.UUID
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

    @Volatile private var sessionId: String? = null

    fun start(session: String? = null) {
        sessionId = session
        if (!installed.compareAndSet(false, true)) {
            flushPending()
            return
        }
        flushPending()
        reportHistoricalCrashes()
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                persistAndEmit(thread, throwable)
            } finally {
                val previous = previousHandler
                if (previous != null) previous.uncaughtException(thread, throwable)
                else {
                    android.os.Process.killProcess(android.os.Process.myPid())
                    kotlin.system.exitProcess(10)
                }
            }
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
            "crash_id" to UUID.randomUUID().toString(),
            "occurred_at_ms" to System.currentTimeMillis(),
            "process_id" to android.os.Process.myPid(),
            "session_id" to sessionId,
            "event_type" to "native_crash",
            "exception_type" to (throwable.javaClass.name),
            "message" to (throwable.message ?: throwable.toString()),
            "stack" to stack,
            "thread" to (thread.name ?: "unknown"),
            "is_fatal" to true,
            "platform" to "android",
            "crash_source" to "uncaught_exception",
        )
        enqueue(payload)
    }

    private fun recordsDir(): File = File(context.filesDir, "ftm_crash_records").apply { mkdirs() }

    /** Atomic JSON write. Android [File.renameTo] fails when the destination already exists. */
    private fun writeJsonAtomic(file: File, json: JSONObject) {
        val temporary = File(file.parentFile, "${file.name}.tmp")
        FileOutputStream(temporary).use { output ->
            output.write(json.toString().toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        if (file.exists() && !file.delete()) {
            temporary.delete()
            error("Cannot replace crash record ${file.name}")
        }
        check(temporary.renameTo(file)) { "Cannot commit crash record ${file.name}" }
    }

    private fun enqueue(payload: Map<String, Any?>): Boolean {
        val id = payload["crash_id"] as? String ?: UUID.randomUUID().toString()
        val record = payload + ("crash_id" to id)
        try {
            val file = File(recordsDir(), "$id.json")
            if (!file.exists()) {
                val json = JSONObject()
                record.forEach { (k, v) -> json.put(k, v ?: JSONObject.NULL) }
                writeJsonAtomic(file, json)
            }
            mainHandler.post { onCrash(record) }
            return true
        } catch (e: Exception) {
            Log.w(TAG, "persist crash failed", e)
            return false
        }
    }

    fun acknowledge(id: String) {
        // IDs are generated locally; never allow paths from the channel.
        if (!id.matches(Regex("[A-Za-z0-9_-]+"))) return
        val file = File(recordsDir(), "$id.json")
        if (!file.exists()) return
        val record = JSONObject(file.readText())
        val timestamp = record.optLong("exit_timestamp_ms", 0L)
        val jvmTimestamp = if (record.optString("crash_source") == "uncaught_exception")
            record.optLong("occurred_at_ms", 0L) else 0L
        if (timestamp > 0 || jvmTimestamp > 0) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val acknowledged = prefs.getStringSet(KEY_ACKNOWLEDGED, emptySet())!!.toMutableSet()
            val pid = record.optInt("process_id")
            if (timestamp > 0) acknowledged.add("exit-$timestamp-$pid")
            if (jvmTimestamp > 0) acknowledged.add("jvm-$jvmTimestamp-$pid")
            while (acknowledged.size > 128) {
                acknowledged.remove(acknowledged.minByOrNull {
                    it.split('-').getOrNull(1)?.toLongOrNull() ?: 0L
                })
            }
            check(prefs.edit().putStringSet(KEY_ACKNOWLEDGED, acknowledged).commit())
        }
        file.delete()
    }

    fun replayPending() {
        if (installed.get()) flushPending()
    }

    private fun flushPending() {
        // Migrate the previous single-record format without deleting before commit.
        val legacy = pendingFile()
        if (legacy.exists()) {
            try {
                val json = JSONObject(legacy.readText())
                val id = "legacy-${legacy.lastModified()}"
                json.put("crash_id", id)
                val target = File(recordsDir(), "$id.json")
                if (!target.exists()) target.writeText(json.toString())
                legacy.delete()
            } catch (e: Exception) { Log.w(TAG, "legacy crash read failed", e) }
        }
        recordsDir().listFiles()?.filter { it.extension == "json" }?.forEach { file ->
            try {
                val json = JSONObject(file.readText())
                val map = mutableMapOf<String, Any?>()
                json.keys().forEach { key -> map[key] = json.opt(key).takeUnless { it == JSONObject.NULL } }
                mainHandler.post { onCrash(map) }
            } catch (e: Exception) { Log.w(TAG, "pending crash read failed", e) }
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
            val acknowledged = prefs.getStringSet(KEY_ACKNOWLEDGED, emptySet())!!
            val processHint = context.packageName
            val history = am.getHistoricalProcessExitReasons(null, 0, 12)
                .asSequence()
                .filter {
                    (it.reason == ApplicationExitInfo.REASON_CRASH ||
                        it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) &&
                        it.timestamp > watermark &&
                        "exit-${it.timestamp}-${it.pid}" !in acknowledged &&
                        !(it.reason == ApplicationExitInfo.REASON_CRASH && acknowledged.any { id ->
                            val parts = id.split('-')
                            parts.size == 3 && parts[0] == "jvm" &&
                                parts[2] == it.pid.toString() &&
                                kotlin.math.abs((parts[1].toLongOrNull() ?: 0L) - it.timestamp) < 10_000
                        })
                }
                .sortedBy { it.timestamp }
                .toList()

            if (history.isEmpty()) {
                emitTombstoneOnly()
                return
            }

            for (latest in history) {
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
                // A persisted JVM exception and ExitInfo can describe the same crash.
                val hasPendingJvm = recordsDir().listFiles()?.any { file ->
                    try {
                        val record = JSONObject(file.readText())
                        val matches = record.optString("crash_source") == "uncaught_exception" &&
                            record.optLong("process_id") == latest.pid.toLong() &&
                            kotlin.math.abs(record.optLong("occurred_at_ms") - latest.timestamp) < 10_000
                        if (matches) {
                            record.put("exit_timestamp_ms", latest.timestamp)
                            writeJsonAtomic(file, record)
                        }
                        matches
                    } catch (e: Exception) {
                        Log.w(TAG, "jvm pending merge failed", e)
                        false
                    }
                } == true
                if (hasPendingJvm && latest.reason == ApplicationExitInfo.REASON_CRASH) continue
                enqueue(
                        buildMap {
                            put("crash_id", "exit-${latest.timestamp}-${latest.pid}")
                            put("occurred_at_ms", latest.timestamp)
                            put("process_id", latest.pid)
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
        val persisted = enqueue(
                mapOf(
                    "crash_id" to "tomb-$stamp",
                    "occurred_at_ms" to stamp,
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
        if (!persisted) return
        // commit：避免 apply 异步落盘前进程被杀导致 watermark 丢失、下次重复回捞
        check(
            prefs.edit()
                .putLong(KEY_TOMBSTONE_AT, maxOf(stamp, System.currentTimeMillis()))
                .commit(),
        )
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
        private const val KEY_ACKNOWLEDGED = "acknowledged_exit_ids"
        private const val KEY_WATERMARK = "exit_info_crash_watermark_ms"
        private const val KEY_TOMBSTONE_AT = "tombstone_reported_at_ms"
    }
}
