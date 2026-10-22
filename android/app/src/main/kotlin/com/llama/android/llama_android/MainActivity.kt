package com.llama.android.llama_android

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CONTROL = "llama/control"
        private const val EVENTS = "llama/events"
        private const val PICK_MODEL = 4711
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LlamaEngine.init(applicationContext)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                LlamaEngine.attachSink(events)
            }

            override fun onCancel(arguments: Any?) {
                LlamaEngine.attachSink(null)
            }
        })

        MethodChannel(messenger, CONTROL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(LlamaEngine.status())
                "logs" -> result.success(LlamaEngine.logs())
                "loadChats" -> result.success(LlamaEngine.loadChats())
                "saveChats" -> result.success(
                    LlamaEngine.saveChats(call.argument<String>("json") ?: "")
                )
                "download" -> {
                    LlamaEngine.download(call.argument<String>("backend") ?: "cpu")
                    result.success(null)
                }
                "deleteBackend" -> result.success(LlamaEngine.deleteBackend(call.argument<String>("backend") ?: "cpu"))
                "start" -> {
                    val cfg = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    val intent = Intent(this, LlamaService::class.java).apply {
                        action = LlamaService.ACTION_START
                        putExtra("backend", cfg["backend"] as? String ?: "cpu")
                        putExtra("model", cfg["model"] as? String)
                        putExtra("ctx", (cfg["ctx"] as? Number)?.toInt() ?: 4096)
                        putExtra("threads", (cfg["threads"] as? Number)?.toInt() ?: 4)
                        putExtra("ngl", (cfg["ngl"] as? Number)?.toInt() ?: 0)
                        putExtra("ub", (cfg["ub"] as? Number)?.toInt() ?: 512)
                        putExtra("fa", cfg["fa"] as? String ?: "auto")
                        putExtra("lan", cfg["lan"] == true)
                        putExtra("apiKey", cfg["apiKey"] as? String ?: "")
                    }
                    startForegroundService(intent)
                    result.success(null)
                }
                "stop" -> {
                    startService(Intent(this, LlamaService::class.java).apply { action = LlamaService.ACTION_STOP })
                    result.success(null)
                }
                "pickModel" -> {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    startActivityForResult(intent, PICK_MODEL)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == PICK_MODEL) {
            val uri: Uri? = data?.data
            if (resultCode == Activity.RESULT_OK && uri != null) {
                LlamaEngine.importModel(uri)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
