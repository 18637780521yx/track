package com.fasttrack.sdk

data class TrackerConfig(
    val maxBatchSize: Int = 100,
    val maxRetryCount: Int = 5,
    val flushIntervalMs: Long = 15_000L,
    val maxCachedEvents: Int = 10_000,
    val sessionTimeoutMs: Long = 30 * 60_000L,
    val retryBackoffBaseMs: Long = 2_000L,
    val retryBackoffMaxMs: Long = 60_000L,
    val retryCoolOffMs: Long = 30 * 60_000L,
    val enableDebugLog: Boolean = false,
    val compressRequest: Boolean = false,
    val dryRun: Boolean = false,
    val environment: String? = null,
    val checkNetworkBeforeFlush: Boolean = true,
    val enableCrashReporting: Boolean = true,
    val enableAnrWatchdog: Boolean = true,
    val anrTimeoutMs: Long = 5_000L,
)

data class FlushResult(
    val sentCount: Int = 0,
    val failedCount: Int = 0,
    val droppedCount: Int = 0,
    val lastError: String? = null,
)

data class SessionInfo(
    val id: String,
    val startedAtMs: Long,
    val lastActiveAtMs: Long,
)

data class UploadResult(
    val success: Boolean,
    val shouldRetry: Boolean,
    val error: String? = null,
)
