package com.fasttrack.demo

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.fasttrack.sdk.FastTracker
import com.fasttrack.sdk.TrackerConfig

class MainActivity : AppCompatActivity() {
    private var inited = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val urlInput = findViewById<EditText>(R.id.urlInput)
        val status = findViewById<TextView>(R.id.status)

        findViewById<Button>(R.id.btnInit).setOnClickListener {
            val url = urlInput.text.toString().trim().ifEmpty { FastTracker.DEFAULT_TRACK_URL }
            FastTracker.init(
                url = url,
                config = TrackerConfig(
                    enableDebugLog = true,
                    maxBatchSize = 10,
                    flushIntervalMs = 5_000L,
                    anrTimeoutMs = 3_000L,
                ),
            )
            inited = true
            status.text = "Initialized → $url"
        }

        findViewById<Button>(R.id.btnTrack).setOnClickListener {
            if (!inited) {
                status.text = "Init first"
                return@setOnClickListener
            }
            FastTracker.track("page_view", mapOf("page" to "demo_home"))
            status.text = "Tracked page_view"
        }

        findViewById<Button>(R.id.btnIdentify).setOnClickListener {
            FastTracker.identify("demo_user")
            status.text = "Identified demo_user"
        }

        findViewById<Button>(R.id.btnFlush).setOnClickListener {
            FastTracker.flush()
            status.text = "Flush requested"
        }

        findViewById<Button>(R.id.btnCaptureError).setOnClickListener {
            if (!inited) {
                status.text = "Init first"
                return@setOnClickListener
            }
            try {
                throw IllegalStateException("demo non-fatal error")
            } catch (t: Throwable) {
                FastTracker.captureException(t, mapOf("page" to "demo"))
            }
            status.text = "Captured non-fatal exception"
        }

        findViewById<Button>(R.id.btnCrash).setOnClickListener {
            if (!inited) {
                status.text = "Init first"
                return@setOnClickListener
            }
            status.text = "Crashing…"
            Handler(Looper.getMainLooper()).post {
                throw RuntimeException("demo fatal crash")
            }
        }

        findViewById<Button>(R.id.btnAnr).setOnClickListener {
            if (!inited) {
                status.text = "Init first"
                return@setOnClickListener
            }
            status.text = "Blocking main thread (ANR watchdog)…"
            Thread.sleep(6_000)
        }
    }
}
