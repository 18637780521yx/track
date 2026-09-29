package com.fasttrack.sdk.stability

import android.os.Process

internal class CrashReporter(
    private val pendingStore: PendingStabilityStore,
    private val onCrashQueued: (name: String, properties: Map<String, Any?>) -> Unit,
) {
    @Volatile
    private var installed = false

    fun install() {
        if (installed) return
        installed = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val props = StabilityPayload.fromThrowable(throwable, isFatal = true)
                pendingStore.writePending(
                    StabilityPayload.EVENT_CRASH,
                    props,
                    System.currentTimeMillis(),
                )
                onCrashQueued(StabilityPayload.EVENT_CRASH, props)
            } catch (_: Exception) {
                // never block crash path
            }
            if (previous != null) {
                previous.uncaughtException(thread, throwable)
            } else {
                Process.killProcess(Process.myPid())
                System.exit(10)
            }
        }
    }
}
