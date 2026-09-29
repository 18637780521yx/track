package com.fasttrack.sdk.stability

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

internal class ExitInfoCollector(
    private val context: Context,
    private val getLastTs: () -> Long,
    private val setLastTs: (Long) -> Unit,
    private val onAnr: (description: String, stack: String) -> Unit,
) {
    fun collectIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            collectR()
        } catch (_: Exception) {
        }
    }

    private fun collectR() {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val list = am.getHistoricalProcessExitReasons(context.packageName, 0, 5)
        val lastTs = getLastTs()
        var maxTs = lastTs
        for (info in list) {
            val ts = info.timestamp
            if (ts <= lastTs) continue
            if (ts > maxTs) maxTs = ts
            if (info.reason != ApplicationExitInfo.REASON_ANR) continue
            val desc = info.description ?: "ANR from ApplicationExitInfo"
            val stack = try {
                info.traceInputStream?.bufferedReader()?.use { it.readText() }?.take(32_000) ?: desc
            } catch (_: Exception) {
                desc
            }
            onAnr(desc, stack)
        }
        if (maxTs > lastTs) setLastTs(maxTs)
    }
}
