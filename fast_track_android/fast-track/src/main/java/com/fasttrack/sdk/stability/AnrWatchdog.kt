package com.fasttrack.sdk.stability

import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Soft ANR detector: ping main thread; if not acknowledged within [timeoutMs], report app_anr.
 */
internal class AnrWatchdog(
    private val timeoutMs: Long,
    private val onAnr: (blockedMs: Long, mainStack: String) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pingId = AtomicLong(0)
    private val lastAckId = AtomicLong(0)
    private val reporting = AtomicBoolean(false)
    private var lastReportAt = 0L
    @Volatile private var running = false
    private var watcher: Thread? = null

    fun start() {
        if (running) return
        running = true
        watcher = Thread({
            while (running && !Thread.currentThread().isInterrupted) {
                val id = pingId.incrementAndGet()
                mainHandler.post { lastAckId.set(id) }
                try {
                    Thread.sleep(timeoutMs)
                } catch (_: InterruptedException) {
                    break
                }
                if (!running) break
                if (lastAckId.get() >= id) continue
                val now = System.currentTimeMillis()
                if (now - lastReportAt <= timeoutMs * 3) continue
                if (!reporting.compareAndSet(false, true)) continue
                try {
                    lastReportAt = now
                    onAnr(timeoutMs, StabilityPayload.mainThreadStack())
                } finally {
                    reporting.set(false)
                }
            }
        }, "fast-track-anr-watchdog").also {
            it.isDaemon = true
            it.start()
        }
    }

    fun stop() {
        running = false
        watcher?.interrupt()
        watcher = null
    }
}
