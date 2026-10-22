package com.llama.android.llama_android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

class LlamaService : Service() {
    companion object {
        const val ACTION_START = "com.llama.android.START"
        const val ACTION_STOP = "com.llama.android.STOP"
        const val ACTION_DOWNLOAD = "com.llama.android.DOWNLOAD"
        private const val CHANNEL = "llama"
        private const val NOTIFICATION_ID = 0x1a3

        @Volatile var instance: LlamaService? = null
    }

    private var text = "llama.cpp"

    override fun onCreate() {
        super.onCreate()
        instance = this
        LlamaEngine.init(this)
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "llama.cpp server", NotificationManager.IMPORTANCE_LOW)
            )
        }
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> LlamaEngine.start(
                mapOf<String, Any?>(
                    "backend" to intent.getStringExtra("backend"),
                    "model" to intent.getStringExtra("model"),
                    "ctx" to intent.getIntExtra("ctx", 4096),
                    "threads" to intent.getIntExtra("threads", 4),
                    "ngl" to intent.getIntExtra("ngl", 0),
                    "ub" to intent.getIntExtra("ub", 512),
                    "fa" to (intent.getStringExtra("fa") ?: "auto"),
                    "lan" to intent.getBooleanExtra("lan", false),
                    "apiKey" to (intent.getStringExtra("apiKey") ?: ""),
                )
            )
            ACTION_DOWNLOAD -> intent.getStringExtra("backend")?.let { LlamaEngine.download(it) }
            ACTION_STOP -> LlamaEngine.stop()
        }
        return START_NOT_STICKY
    }

    fun update(newText: String) {
        text = newText
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("llama.cpp")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        LlamaEngine.shutdown()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
