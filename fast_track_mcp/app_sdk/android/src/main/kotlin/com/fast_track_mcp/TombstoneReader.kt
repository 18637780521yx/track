package com.fast_track_mcp

import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File

/**
 * 下次启动回捞 tombstone / ExitInfo 轨迹。
 *
 * 生产环境可读来源优先 [ApplicationExitInfo.traceInputStream]（系统给本 app 的官方通道）。
 * `/data/tombstones` 仅在可列目录时尝试（多为 debuggable / 特殊 ROM）。
 */
internal object TombstoneReader {
    private const val TAG = "ftm.tombstone"
    private const val MAX_CHARS = 24_576
    private const val LAST_FILE = "ftm_last_tombstone.txt"
    private const val SYSTEM_DIR = "/data/tombstones"

    data class Result(
        val text: String,
        val source: String,
        val path: String? = null,
    )

    fun fromExitInfo(info: ApplicationExitInfo): Result? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val text = try {
            info.traceInputStream?.bufferedReader()?.use { it.readText() }?.trim().orEmpty()
        } catch (e: Exception) {
            Log.w(TAG, "ExitInfo trace read failed: $e")
            ""
        }
        if (text.isEmpty()) return null
        return Result(text = text.take(MAX_CHARS), source = "app_exit_info_trace")
    }

    /** 系统 tombstone 目录（通常无权限；有则取最新且内容非空的一份）。 */
    fun fromSystemDir(processNameHint: String?): Result? {
        val dir = File(SYSTEM_DIR)
        if (!dir.isDirectory || !dir.canRead()) return null
        val files = try {
            dir.listFiles { f -> f.isFile && f.name.startsWith("tombstone") }
                ?.sortedByDescending { it.lastModified() }
        } catch (e: Exception) {
            Log.w(TAG, "list $SYSTEM_DIR failed: $e")
            return null
        } ?: return null

        for (file in files.take(6)) {
            val text = readFileSafe(file) ?: continue
            if (processNameHint != null &&
                processNameHint.isNotEmpty() &&
                !text.contains(processNameHint)
            ) {
                // 可能是别的进程；仍允许若只有一份匹配时间窗时放宽——这里跳过不匹配
                continue
            }
            if (text.isNotBlank()) {
                return Result(
                    text = text.take(MAX_CHARS),
                    source = "system_tombstone",
                    path = file.absolutePath,
                )
            }
        }
        // 无 process 匹配时退回最新一份（debuggable 场景）
        val newest = files.firstOrNull() ?: return null
        val text = readFileSafe(newest) ?: return null
        if (text.isBlank()) return null
        return Result(
            text = text.take(MAX_CHARS),
            source = "system_tombstone",
            path = newest.absolutePath,
        )
    }

    fun persistCopy(context: Context, text: String) {
        if (text.isBlank()) return
        try {
            File(context.filesDir, LAST_FILE).writeText(text.take(MAX_CHARS))
        } catch (e: Exception) {
            Log.w(TAG, "persist tombstone copy failed: $e")
        }
    }

    /** 若 ExitInfo/系统目录都空，回读上次落盘副本（按 watermark 外的调用方决定是否上报）。 */
    fun fromPersistedCopy(context: Context): Result? {
        val file = File(context.filesDir, LAST_FILE)
        if (!file.exists()) return null
        val text = readFileSafe(file) ?: return null
        if (text.isBlank()) return null
        return Result(
            text = text.take(MAX_CHARS),
            source = "persisted_tombstone",
            path = file.absolutePath,
        )
    }

    fun clearPersistedCopy(context: Context) {
        try {
            File(context.filesDir, LAST_FILE).delete()
        } catch (_: Exception) {
        }
    }

    /**
     * 合并策略：ExitInfo trace > 系统目录 > （仅当 [allowPersistedFallback]）落盘副本。
     */
    fun resolve(
        context: Context,
        exitInfo: ApplicationExitInfo?,
        processNameHint: String?,
        allowPersistedFallback: Boolean = false,
    ): Result? {
        exitInfo?.let { fromExitInfo(it) }?.also {
            persistCopy(context, it.text)
            return it
        }
        fromSystemDir(processNameHint)?.also {
            persistCopy(context, it.text)
            return it
        }
        if (allowPersistedFallback) {
            return fromPersistedCopy(context)
        }
        return null
    }

    private fun readFileSafe(file: File): String? {
        return try {
            if (!file.canRead()) return null
            file.readText()
        } catch (e: Exception) {
            Log.w(TAG, "read ${file.path} failed: $e")
            null
        }
    }
}
