package com.fasttrack.sdk

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import java.util.Locale
import java.util.TimeZone

internal object AutoProperties {
    fun staticProperties(context: Context, environment: String?): Map<String, Any?> {
        val appInfo = try {
            context.packageManager.getPackageInfo(context.packageName, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
        val env = environment ?: if (isDebuggable(context)) "sandbox" else "production"
        val udid = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        return mapOf(
            "environment" to env,
            "build_mode" to if (isDebuggable(context)) "debug" else "release",
            "sdk_version" to "1.0.0",
            "device_os" to "android",
            "device_os_version" to Build.VERSION.RELEASE,
            "device_model" to Build.MODEL,
            "device_brand" to Build.BRAND,
            "app_name" to (appInfo?.applicationInfo?.loadLabel(context.packageManager)?.toString() ?: ""),
            "app_version" to (appInfo?.versionName ?: ""),
            "app_build" to (
                when {
                    appInfo == null -> ""
                    Build.VERSION.SDK_INT >= 28 -> appInfo.longVersionCode.toString()
                    else -> @Suppress("DEPRECATION") appInfo.versionCode.toString()
                }
            ),
            "app_package" to context.packageName,
            "device_udid" to (udid ?: ""),
            "locale" to Locale.getDefault().toString(),
            "language" to Locale.getDefault().language,
        )
    }

    fun dynamicProperties(context: Context? = null): Map<String, Any?> {
        val offsetHours = TimeZone.getDefault().rawOffset / 3_600_000.0
        val network = context?.let { NetworkMonitor.resolveType(it) } ?: "unknown"
        return mapOf(
            "timezone_offset_hours" to offsetHours,
            "network_type" to network,
        )
    }

    private fun isDebuggable(context: Context): Boolean {
        return (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }
}
