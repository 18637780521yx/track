package com.fasttrack.sdk

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * 监听网络可用性变化，上报 `network_change`。
 * 首次回调只记状态，不打点，避免 init 立刻刷一条。
 */
internal class NetworkMonitor(
    context: Context,
    private val onChange: (from: String, to: String) -> Unit,
) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastType: String? = null
    private var started = false

    fun start() {
        if (started) return
        started = true
        lastType = currentType()
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            cm.registerNetworkCallback(request, callback)
        } catch (_: Exception) {
            // some devices / missing permission
        }
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = scheduleCheck()
        override fun onLost(network: Network) = scheduleCheck()
        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) =
            scheduleCheck()
    }

    private fun scheduleCheck() {
        mainHandler.removeCallbacks(checkRunnable)
        // 合并短时抖动
        mainHandler.postDelayed(checkRunnable, 400L)
    }

    private val checkRunnable = Runnable {
        val next = currentType()
        val prev = lastType
        if (prev != null && prev != next) {
            onChange(prev, next)
        }
        lastType = next
    }

    fun currentType(): String = resolveType(appContext)

    companion object {
        fun resolveType(context: Context): String {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return "unknown"
            return try {
                if (Build.VERSION.SDK_INT >= 23) {
                    val network = cm.activeNetwork ?: return "none"
                    val caps = cm.getNetworkCapabilities(network) ?: return "none"
                    when {
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
                        else -> "other"
                    }
                } else {
                    @Suppress("DEPRECATION")
                    when (cm.activeNetworkInfo?.type) {
                        ConnectivityManager.TYPE_WIFI -> "wifi"
                        ConnectivityManager.TYPE_MOBILE -> "cellular"
                        ConnectivityManager.TYPE_ETHERNET -> "ethernet"
                        null -> "none"
                        else -> "other"
                    }
                }
            } catch (_: Exception) {
                "unknown"
            }
        }
    }
}
