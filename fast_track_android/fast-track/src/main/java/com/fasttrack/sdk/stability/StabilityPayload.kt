package com.fasttrack.sdk.stability

import android.os.Looper
import java.io.PrintWriter
import java.io.StringWriter

internal object StabilityPayload {
    const val EVENT_CRASH = "app_crash"
    const val EVENT_ERROR = "app_error"
    const val EVENT_ANR = "app_anr"

    fun fromThrowable(
        throwable: Throwable,
        isFatal: Boolean,
        extras: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> {
        val type = throwable.javaClass.name
        val stack = stackTraceString(throwable)
        val props = linkedMapOf<String, Any?>(
            "exception_type" to type,
            "message" to (throwable.message ?: ""),
            "stack" to stack,
            "thread" to (Thread.currentThread().name ?: ""),
            "is_fatal" to isFatal,
            "fingerprint" to StackFingerprint.of(type, stack),
        )
        props.putAll(extras)
        return props
    }

    fun anr(
        blockedMs: Long,
        source: String,
        mainStack: String,
        extras: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> {
        val type = "ApplicationNotResponding"
        val props = linkedMapOf<String, Any?>(
            "exception_type" to type,
            "message" to "Main thread blocked for ${blockedMs}ms ($source)",
            "stack" to mainStack,
            "thread" to "main",
            "is_fatal" to false,
            "blocked_ms" to blockedMs,
            "anr_source" to source,
            "fingerprint" to StackFingerprint.of(type, mainStack),
        )
        props.putAll(extras)
        return props
    }

    fun stackTraceString(throwable: Throwable): String {
        val sw = StringWriter()
        throwable.printStackTrace(PrintWriter(sw))
        return sw.toString().take(32_000)
    }

    fun mainThreadStack(): String {
        val main = Looper.getMainLooper().thread
        val sb = StringBuilder()
        for (el in main.stackTrace) {
            sb.append("at ").append(el.toString()).append('\n')
            if (sb.length > 32_000) break
        }
        return sb.toString()
    }
}
