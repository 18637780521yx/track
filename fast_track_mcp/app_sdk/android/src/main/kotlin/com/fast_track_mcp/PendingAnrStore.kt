package com.fast_track_mcp

import android.content.Context
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File

/** Historical ANRs remain here until Dart confirms durable queue insertion. */
internal class PendingAnrStore(context: Context) {
    private val directory = File(context.filesDir, "ftm_anr_records")
    private val prefs = context.getSharedPreferences("ftm_anr", Context.MODE_PRIVATE)

    fun isAcknowledged(id: String): Boolean =
        id in (prefs.getStringSet("acknowledged_ids", emptySet()) ?: emptySet())

    fun put(id: String, payload: Map<String, Any?>) {
        check(directory.isDirectory || directory.mkdirs())
        val file = File(directory, "$id.json")
        val atomic = AtomicFile(file)
        if (file.exists()) return
        val json = JSONObject()
        payload.forEach { (key, value) -> json.put(key, value ?: JSONObject.NULL) }
        val output = atomic.startWrite()
        try {
            output.write(json.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(output)
        } catch (error: Throwable) {
            atomic.failWrite(output)
            throw error
        }
    }

    fun readPending(): List<Map<String, Any?>> =
        directory.listFiles()?.filter { it.extension == "json" }?.mapNotNull { file ->
            try {
                val json = JSONObject(AtomicFile(file).readFully().toString(Charsets.UTF_8))
                buildMap { json.keys().forEach { key ->
                    put(key, json.opt(key).takeUnless { it == JSONObject.NULL })
                } }
            } catch (e: Exception) {
                android.util.Log.w("ftm.anr", "Pending ANR read failed; record retained", e)
                null
            }
        } ?: emptyList()

    fun acknowledge(id: String) {
        require(id.matches(Regex("[A-Za-z0-9_-]+")))
        val acknowledged = (prefs.getStringSet("acknowledged_ids", emptySet()) ?: emptySet()).toMutableSet()
        acknowledged.add(id)
        // ExitInfo exposes only a short history; retain the most recent 128 IDs.
        val retained = acknowledged.sortedByDescending {
            it.split('-').getOrNull(1)?.toLongOrNull() ?: 0L
        }.take(128).toSet()
        check(prefs.edit().putStringSet("acknowledged_ids", retained).commit())
        AtomicFile(File(directory, "$id.json")).delete()
    }
}
