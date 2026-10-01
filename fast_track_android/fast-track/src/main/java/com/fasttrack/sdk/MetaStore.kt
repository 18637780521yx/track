package com.fasttrack.sdk

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

internal class MetaStore(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("fast_track_meta", Context.MODE_PRIVATE)

    var anonymousId: String?
        get() = prefs.getString(KEY_ANON, null)
        set(value) = prefs.edit().putString(KEY_ANON, value).apply()

    var distinctId: String?
        get() = prefs.getString(KEY_DISTINCT, null)
        set(value) {
            if (value.isNullOrEmpty()) {
                prefs.edit().remove(KEY_DISTINCT).apply()
            } else {
                prefs.edit().putString(KEY_DISTINCT, value).apply()
            }
        }

    var optedOut: Boolean
        get() = prefs.getBoolean(KEY_OPT_OUT, false)
        set(value) = prefs.edit().putBoolean(KEY_OPT_OUT, value).apply()

    var firstOpenDone: Boolean
        get() = prefs.getBoolean(KEY_FIRST_OPEN, false)
        set(value) = prefs.edit().putBoolean(KEY_FIRST_OPEN, value).apply()

    var lastExitInfoTs: Long
        get() = prefs.getLong(KEY_EXIT_INFO_TS, 0L)
        set(value) = prefs.edit().putLong(KEY_EXIT_INFO_TS, value).apply()

    var lastAppVersion: String?
        get() = prefs.getString(KEY_LAST_APP_VERSION, null)
        set(value) {
            if (value.isNullOrEmpty()) {
                prefs.edit().remove(KEY_LAST_APP_VERSION).apply()
            } else {
                prefs.edit().putString(KEY_LAST_APP_VERSION, value).apply()
            }
        }

    var lastAppBuild: String?
        get() = prefs.getString(KEY_LAST_APP_BUILD, null)
        set(value) {
            if (value.isNullOrEmpty()) {
                prefs.edit().remove(KEY_LAST_APP_BUILD).apply()
            } else {
                prefs.edit().putString(KEY_LAST_APP_BUILD, value).apply()
            }
        }

    fun loadSession(): SessionInfo? {
        val id = prefs.getString(KEY_SESSION_ID, null) ?: return null
        val started = prefs.getLong(KEY_SESSION_STARTED, 0L)
        val last = prefs.getLong(KEY_SESSION_LAST, 0L)
        if (started == 0L || last == 0L) return null
        return SessionInfo(id, started, last)
    }

    fun saveSession(session: SessionInfo) {
        prefs.edit()
            .putString(KEY_SESSION_ID, session.id)
            .putLong(KEY_SESSION_STARTED, session.startedAtMs)
            .putLong(KEY_SESSION_LAST, session.lastActiveAtMs)
            .apply()
    }

    fun loadCommonProperties(): MutableMap<String, Any?> {
        val raw = prefs.getString(KEY_COMMON, null) ?: return mutableMapOf()
        return jsonToMap(JSONObject(raw)).toMutableMap()
    }

    fun saveCommonProperties(map: Map<String, Any?>) {
        prefs.edit().putString(KEY_COMMON, JSONObject(map).toString()).apply()
    }

    companion object {
        private const val KEY_ANON = "anonymous_id"
        private const val KEY_DISTINCT = "distinct_id"
        private const val KEY_OPT_OUT = "opt_out"
        private const val KEY_FIRST_OPEN = "first_open_done"
        private const val KEY_SESSION_ID = "session_id"
        private const val KEY_SESSION_STARTED = "session_started"
        private const val KEY_SESSION_LAST = "session_last"
        private const val KEY_COMMON = "common_properties"
        private const val KEY_EXIT_INFO_TS = "last_exit_info_ts"
        private const val KEY_LAST_APP_VERSION = "last_app_version"
        private const val KEY_LAST_APP_BUILD = "last_app_build"

        fun jsonToMap(obj: JSONObject): Map<String, Any?> {
            val out = mutableMapOf<String, Any?>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                out[k] = obj.opt(k)
            }
            return out
        }
    }
}
