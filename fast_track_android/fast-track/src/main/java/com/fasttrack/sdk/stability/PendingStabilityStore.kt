package com.fasttrack.sdk.stability

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * Crash-time durable store: write JSON files before process dies, replay on next init.
 */
internal class PendingStabilityStore(context: Context) {
    private val dir = File(context.filesDir, "fast_track_stability").also { it.mkdirs() }

    fun writePending(eventName: String, properties: Map<String, Any?>, timestampMs: Long): File {
        val file = File(dir, "pending_${UUID.randomUUID()}.json")
        val json = JSONObject()
        json.put("name", eventName)
        json.put("timestamp_ms", timestampMs)
        json.put("properties", JSONObject(properties.filterValues { it != null }))
        file.writeText(json.toString())
        return file
    }

    fun loadAll(): List<PendingItem> {
        val files = dir.listFiles { f -> f.isFile && f.name.startsWith("pending_") } ?: return emptyList()
        val items = mutableListOf<PendingItem>()
        for (file in files.sortedBy { it.lastModified() }) {
            try {
                val json = JSONObject(file.readText())
                val propsJson = json.optJSONObject("properties") ?: JSONObject()
                val props = mutableMapOf<String, Any?>()
                propsJson.keys().forEach { key -> props[key] = propsJson.opt(key) }
                items.add(
                    PendingItem(
                        file = file,
                        name = json.optString("name"),
                        timestampMs = json.optLong("timestamp_ms", System.currentTimeMillis()),
                        properties = props,
                    )
                )
            } catch (_: Exception) {
                file.delete()
            }
        }
        return items
    }

    data class PendingItem(
        val file: File,
        val name: String,
        val timestampMs: Long,
        val properties: Map<String, Any?>,
    )
}
