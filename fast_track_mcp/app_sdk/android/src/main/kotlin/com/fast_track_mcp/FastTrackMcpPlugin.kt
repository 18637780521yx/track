package com.fast_track_mcp

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FastTrackMcpPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var anrEvents: EventChannel
    private lateinit var crashEvents: EventChannel
    private var anrSink: EventChannel.EventSink? = null
    private var crashSink: EventChannel.EventSink? = null
    private var anrDetector: AnrDetector? = null
    private var crashDetector: NativeCrashDetector? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD)
        methodChannel.setMethodCallHandler(this)

        anrEvents = EventChannel(binding.binaryMessenger, ANR_EVENTS)
        anrEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                anrSink = events
                anrDetector?.replayPending()
            }

            override fun onCancel(arguments: Any?) {
                anrSink = null
            }
        })

        crashEvents = EventChannel(binding.binaryMessenger, CRASH_EVENTS)
        crashEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                crashSink = events
                crashDetector?.replayPending()
            }

            override fun onCancel(arguments: Any?) {
                crashSink = null
            }
        })

        anrDetector = AnrDetector(binding.applicationContext) { payload ->
            val withType = HashMap(payload)
            withType["event_type"] = "anr"
            mainHandler.post { anrSink?.success(withType) }
        }
        crashDetector = NativeCrashDetector(binding.applicationContext) { payload ->
            mainHandler.post { crashSink?.success(payload) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        anrDetector?.stop()
        anrDetector = null
        crashDetector?.stop()
        crashDetector = null
        methodChannel.setMethodCallHandler(null)
        anrEvents.setStreamHandler(null)
        crashEvents.setStreamHandler(null)
        anrSink = null
        crashSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 5_000L)
                anrDetector?.start(timeoutMs)
                result.success(mapOf("ok" to true, "mode" to "native"))
            }
            "ackAnr" -> {
                try {
                    call.argument<String>("anr_id")?.let { anrDetector?.acknowledge(it) }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("anr_ack_failed", e.message, null)
                }
            }
            "stop" -> {
                anrDetector?.stop()
                result.success(mapOf("ok" to true))
            }
            "startCrash" -> {
                crashDetector?.start(call.argument<String>("session_id"))
                result.success(mapOf("ok" to true, "mode" to "native"))
            }
            "ackCrash" -> {
                try {
                    call.argument<String>("crash_id")?.let { crashDetector?.acknowledge(it) }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("crash_ack_failed", e.message, null)
                }
            }
            "stopCrash" -> {
                crashDetector?.stop()
                result.success(mapOf("ok" to true))
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val METHOD = "fast_track_mcp/anr"
        const val ANR_EVENTS = "fast_track_mcp/anr_events"
        const val CRASH_EVENTS = "fast_track_mcp/crash_events"
    }
}
