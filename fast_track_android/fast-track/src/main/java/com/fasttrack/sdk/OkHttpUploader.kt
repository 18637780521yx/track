package com.fasttrack.sdk

import com.fasttrack.sdk.db.TrackEventEntity
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPOutputStream

internal class OkHttpUploader(
    private val url: String,
    private val headers: Map<String, String>,
    private val config: TrackerConfig,
) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    fun upload(events: List<TrackEventEntity>): UploadResult {
        if (config.dryRun) {
            return UploadResult(success = true, shouldRetry = false)
        }

        val bodyJson = JSONObject().apply {
            put("events", JSONArray().apply {
                events.forEach { put(eventToJson(it)) }
            })
        }.toString()

        var lastError: String? = null
        var attempt = 0
        while (attempt <= config.maxRetryCount) {
            try {
                val mediaType = "application/json; charset=utf-8".toMediaType()
                val requestBody = if (config.compressRequest) {
                    val compressed = gzip(bodyJson.toByteArray(Charsets.UTF_8))
                    compressed.toRequestBody("application/json".toMediaType())
                } else {
                    bodyJson.toRequestBody(mediaType)
                }

                val builder = Request.Builder().url(url).post(requestBody)
                headers.forEach { (k, v) -> builder.header(k, v) }
                if (config.compressRequest) {
                    builder.header("Content-Encoding", "gzip")
                }

                client.newCall(builder.build()).execute().use { resp ->
                    val code = resp.code
                    if (code in 200..299) {
                        return UploadResult(success = true, shouldRetry = false)
                    }
                    lastError = "HTTP $code ${resp.message}"
                    val permanent = code in 400..499 && code !in listOf(401, 403, 429)
                    if (permanent) {
                        return UploadResult(success = false, shouldRetry = false, error = lastError)
                    }
                }
            } catch (e: Exception) {
                lastError = e.message
            }

            if (attempt >= config.maxRetryCount) break
            val delay = (config.retryBackoffBaseMs * (1L shl attempt.coerceAtMost(5)))
                .coerceAtMost(config.retryBackoffMaxMs)
            Thread.sleep(delay)
            attempt++
        }
        return UploadResult(success = false, shouldRetry = true, error = lastError)
    }

    private fun eventToJson(e: TrackEventEntity): JSONObject {
        val props = try {
            JSONObject(e.propertiesJson)
        } catch (_: Exception) {
            JSONObject()
        }
        val common = try {
            JSONObject(e.commonPropertiesJson)
        } catch (_: Exception) {
            JSONObject()
        }
        return JSONObject().apply {
            put("event_id", e.eventId)
            put("name", e.name)
            put("properties", props)
            put("common_properties", common)
            if (e.distinctId != null) put("distinct_id", e.distinctId) else put("distinct_id", JSONObject.NULL)
            put("anonymous_id", e.anonymousId)
            put("session_id", e.sessionId)
            put("timestamp", isoUtc(e.timestampMs))
        }
    }

    private fun isoUtc(ms: Long): String {
        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
        sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return sdf.format(java.util.Date(ms))
    }

    private fun gzip(data: ByteArray): ByteArray {
        val bos = ByteArrayOutputStream()
        GZIPOutputStream(bos).use { it.write(data) }
        return bos.toByteArray()
    }
}
