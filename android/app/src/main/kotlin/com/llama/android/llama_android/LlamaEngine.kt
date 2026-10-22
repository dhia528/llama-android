package com.llama.android.llama_android

import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.OpenableColumns
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.NetworkInterface
import java.net.URL
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Owns everything that cannot run from Dart on Android: backend downloads,
 * model import and the llama-server child process.
 */
object LlamaEngine {
    const val PORT = 8080
    private const val TAG_WAKE = "llama:server"

    private lateinit var app: Context
    private val work = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    private val logs = Collections.synchronizedList(ArrayList<String>())
    private val pendingLogs = ArrayList<String>()
    private var logFlushScheduled = false

    @Volatile var state: String = "idle"; private set
    @Volatile private var stateMessage: String? = null
    @Volatile private var backend: String? = null
    @Volatile private var modelPath: String? = null
    @Volatile private var process: Process? = null
    @Volatile private var stopping = false
    @Volatile private var downloading: String? = null
    private var wakeLock: PowerManager.WakeLock? = null

    fun init(context: Context) {
        if (!::app.isInitialized) app = context.applicationContext
    }

    fun attachSink(streamSink: EventChannel.EventSink?) {
        sink = streamSink
    }

    fun logs(): List<String> = synchronized(logs) { ArrayList(logs) }

    fun status(): Map<String, Any?> {
        val prefs = prefs()
        val model = prefs.getString("model", null)?.let { File(it) }?.takeIf { it.isFile }
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "abi" to Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
            "freeSpace" to app.filesDir.usableSpace,
            "socQualcomm" to isQualcomm(),
            "socName" to socName(),
            "vulkan" to hasVulkan(),
            "wifiIp" to wifiIp(),
            "model" to model?.let {
                mapOf("path" to it.absolutePath, "name" to it.name, "size" to it.length())
            },
            "backends" to BackendStore.specs.associate { spec ->
                spec.id to mapOf(
                    "installed" to BackendStore.installed(app, spec.id),
                    "bytes" to BackendStore.sizeOnDisk(app, spec.id),
                )
            },
            "server" to mapOf(
                "state" to state,
                "message" to stateMessage,
                "port" to PORT,
                "backend" to backend,
                "model" to modelPath,
            ),
            "downloading" to downloading,
        )
    }

    fun download(id: String) {
        if (downloading != null) {
            emit(mapOf("type" to "error", "message" to "A backend download is already running"))
            return
        }
        downloading = id
        LlamaService.instance?.update("Downloading $id backend")
        emit(mapOf("type" to "download", "backend" to id, "received" to 0L, "total" to 0L))
        work.execute {
            var lastEmit = 0L
            try {
                BackendStore.install(
                    app,
                    id,
                    onProgress = { received, total ->
                        val now = System.currentTimeMillis()
                        if (now - lastEmit > 250 || received == total) {
                            lastEmit = now
                            emit(mapOf("type" to "download", "backend" to id, "received" to received, "total" to total))
                        }
                    },
                    onLog = { line -> logLine("backend: $line") },
                )
                emit(mapOf("type" to "download", "backend" to id, "done" to true))
                emitStatus()
            } catch (e: Exception) {
                logLine("backend error: ${e.message}")
                emit(mapOf("type" to "error", "message" to "Backend install failed: ${e.message}"))
            } finally {
                downloading = null
                LlamaService.instance?.update("llama.cpp")
            }
        }
    }

    fun deleteBackend(id: String): Map<String, Any?> {
        if (process != null) {
            return mapOf("ok" to false, "message" to "Stop the server first")
        }
        BackendStore.delete(app, id)
        return mapOf("ok" to true)
    }

    fun start(cfg: Map<String, Any?>) {
        val id = cfg["backend"] as? String ?: "cpu"
        val model = cfg["model"] as? String
        val ctx = (cfg["ctx"] as? Number)?.toInt()?.coerceIn(128, 131_072) ?: 4096
        val threads = (cfg["threads"] as? Number)?.toInt()?.coerceIn(1, 32) ?: 4
        val ngl = (cfg["ngl"] as? Number)?.toInt()?.coerceIn(0, 999) ?: 0
        val ub = (cfg["ub"] as? Number)?.toInt()?.coerceIn(32, 4096) ?: 512
        val fa = (cfg["fa"] as? String).takeIf { it in setOf("auto", "on", "off") } ?: "auto"
        val lan = cfg["lan"] == true
        val apiKey = (cfg["apiKey"] as? String)?.trim().orEmpty()
        val host = if (lan) "0.0.0.0" else "127.0.0.1"

        if (process != null) stopInternal()
        backend = id
        modelPath = model
        stateMessage = null

        if (lan && apiKey.length < 8) {
            fail("Set an API key (8+ characters) before enabling LAN access")
            return
        }
        if (model == null || !File(model).isFile) {
            fail("Choose a GGUF model first")
            return
        }
        val exe = BackendStore.executable(app, id)
        if (!exe.isFile) {
            fail("Backend '$id' is not installed")
            return
        }
        if ((id == "adreno" || id == "hexagon") && !isQualcomm()) {
            fail("Snapdragon backend on a ${socName()} device; use CPU")
            return
        }
        if (!isGguf(File(model))) {
            fail("Model file is not a GGUF file")
            return
        }

        state = "starting"
        emitStatus()
        LlamaService.instance?.update("Loading model…")

        work.execute {
            try {
                preflight(exe, id)
                if (stopping) return@execute
                val cmd = buildCommand(exe, model, ctx, threads, ngl, ub, fa, id, host, apiKey)
                logLine("exec: ${cmd.joinToString(" ").let { if (apiKey.isEmpty()) it else it.replace(apiKey, "***") }}")
                val builder = ProcessBuilder(cmd)
                builder.directory(BackendStore.dir(app, id))
                builder.redirectErrorStream(true)
                applyEnvironment(builder, id)
                val started = builder.start()
                process = started
                acquireWakeLock()
                state = "starting"
                emitStatus()
                startReaders(started)
                startHealthPolling(started, apiKey)
            } catch (e: Exception) {
                fail(describeStartFailure(e))
            }
        }
    }

    fun stop() {
        work.execute { stopInternal() }
    }

    /** Called from Service.onDestroy, where no further work can be queued. */
    fun shutdown() {
        releaseWakeLock()
        process?.destroy()
        process = null
        state = "idle"
        stateMessage = null
        stopping = false
    }

    private fun stopInternal() {
        stopping = true
        val current = process
        process = null
        if (current != null) {
            current.destroy()
            try {
                if (!current.waitFor(5, TimeUnit.SECONDS)) current.destroyForcibly()
            } catch (_: Exception) {
                current.destroyForcibly()
            }
        }
        releaseWakeLock()
        state = "idle"
        stateMessage = null
        stopping = false
        emitStatus()
        LlamaService.instance?.update("llama.cpp")
    }

    fun importModel(uri: Uri) {
        work.execute {
            val prefs = prefs()
            val name = queryDisplayName(uri) ?: "model.gguf"
            val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "model.gguf" }
            val dir = File(app.filesDir, "models").apply { mkdirs() }
            val tmp = File(dir, "$safeName.part")
            val dest = File(dir, safeName)
            try {
                val declared = querySize(uri)
                if (declared > 0 && app.filesDir.usableSpace < declared + 50L * 1024 * 1024) {
                    throw IOException("Not enough free space for this model")
                }
                var copied = 0L
                var lastEmit = 0L
                app.contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(tmp).use { out ->
                        val buf = ByteArray(256 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            copied += n
                            val now = System.currentTimeMillis()
                            if (now - lastEmit > 250) {
                                lastEmit = now
                                emit(mapOf("type" to "model", "received" to copied, "total" to declared))
                            }
                        }
                    }
                } ?: throw IOException("Cannot open the selected file")

                if (!isGguf(tmp)) throw IOException("Selected file is not GGUF")
                if (dest.exists()) dest.delete()
                if (!tmp.renameTo(dest)) throw IOException("Could not store the model")
                prefs.edit().putString("model", dest.absolutePath).apply()
                logLine("model: ${dest.name} (${dest.length() / (1024 * 1024)} MB)")
                emit(
                    mapOf(
                        "type" to "model",
                        "done" to true,
                        "path" to dest.absolutePath,
                        "name" to dest.name,
                        "size" to dest.length(),
                    )
                )
                emitStatus()
            } catch (e: Exception) {
                tmp.delete()
                emit(mapOf("type" to "error", "message" to "Model import failed: ${e.message}"))
            }
        }
    }

    private fun buildCommand(
        exe: File,
        model: String,
        ctx: Int,
        threads: Int,
        ngl: Int,
        ub: Int,
        fa: String,
        id: String,
        host: String,
        apiKey: String,
    ): List<String> {
        val cmd = mutableListOf(
            exe.absolutePath,
            "-m", model,
            "-c", ctx.toString(),
            "-t", threads.toString(),
            "-ngl", ngl.toString(),
            "-fa", fa,
            "-ub", ub.toString(),
            "--host", host,
            "--port", PORT.toString(),
        )
        // Force the Adreno path: without --device llama.cpp prefers the Hexagon
        // backend present in the same package.
        when (id) {
            "adreno" -> cmd += listOf("--device", "GPUOpenCL")
            "hexagon" -> cmd += listOf("--device", "HTP0")
        }
        if (apiKey.isNotEmpty()) cmd += listOf("--api-key", apiKey)
        return cmd
    }

    private fun applyEnvironment(builder: ProcessBuilder, id: String) {
        val env = builder.environment()
        val lib = BackendStore.libraries(app, id).absolutePath
        val existing = env["LD_LIBRARY_PATH"]
        env["LD_LIBRARY_PATH"] = if (existing.isNullOrEmpty()) lib else "$lib:$existing"
        env["HOME"] = app.filesDir.absolutePath
        env["TMPDIR"] = app.cacheDir.absolutePath
        env["GGML_OPENCL_KERNEL_CACHE_DIR"] =
            File(app.filesDir, "opencl-cache").apply { mkdirs() }.absolutePath
        if (id == "hexagon") env["ADSP_LIBRARY_PATH"] = lib
    }

    private fun socName(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MANUFACTURER?.takeIf { it.isNotBlank() } ?: Build.MANUFACTURER
        } else {
            Build.MANUFACTURER
        }

    private fun isQualcomm(): Boolean {
        val markers = buildList {
            add(Build.HARDWARE); add(Build.BOARD); add(Build.MANUFACTURER); add(Build.DEVICE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Build.SOC_MANUFACTURER)
        }.joinToString(" ").lowercase()
        return markers.contains("qualcomm") || markers.contains("qcom")
    }

    private fun hasVulkan(): Boolean = try {
        app.packageManager.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL) ||
            app.packageManager.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_VERSION)
    } catch (_: Exception) {
        false
    }

    private fun wifiIp(): String? = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is java.net.Inet4Address && it.isSiteLocalAddress }
            ?.hostAddress
    } catch (_: Exception) {
        null
    }

    fun loadChats(): String? = try {
        File(app.filesDir, "chats.json").takeIf { it.isFile }?.readText()
    } catch (_: Exception) {
        null
    }

    fun saveChats(json: String): Boolean = try {
        // shortcut: cap keeps a pathological history from filling internal storage.
        if (json.length > 8 * 1024 * 1024) return false
        val target = File(app.filesDir, "chats.json")
        val tmp = File(app.filesDir, "chats.json.tmp")
        tmp.writeText(json)
        if (target.exists()) target.delete()
        tmp.renameTo(target)
    } catch (_: Exception) {
        false
    }

    private fun preflight(exe: File, id: String) {
        val builder = ProcessBuilder(exe.absolutePath, "--version")
        builder.directory(BackendStore.dir(app, id))
        builder.redirectErrorStream(true)
        applyEnvironment(builder, id)
        val probe = builder.start()
        val output = probe.inputStream.bufferedReader().readText()
        if (!probe.waitFor(20, TimeUnit.SECONDS)) {
            probe.destroyForcibly()
            throw IOException("Backend did not answer a version check")
        }
        if (probe.exitValue() != 0) {
            val tail = output.takeLast(600).trim()
            throw IOException(
                "This backend cannot run on this device (exit ${probe.exitValue()}). " +
                    "Use the CPU backend. $tail"
            )
        }
        logLine("preflight ok: " + output.lineSequence().firstOrNull().orEmpty())
    }

    private fun startReaders(started: Process) {
        Thread({
            try {
                started.inputStream.bufferedReader().forEachLine { line ->
                    logLine(line)
                    when {
                        line.contains("server is listening", ignoreCase = true) ||
                            line.contains("HTTP server listening", ignoreCase = true) -> markReady(started)
                    }
                }
            } catch (_: Exception) {
                // stream closed on stop
            }
            val code = try {
                started.waitFor()
            } catch (_: Exception) {
                -1
            }
            if (process === started) {
                process = null
                releaseWakeLock()
                state = if (code == 0) "stopped" else "error"
                stateMessage = "Server exited (code $code)"
                emitStatus()
                LlamaService.instance?.update("llama.cpp stopped")
            }
        }, "llama-output").start()
    }

    private fun startHealthPolling(started: Process, apiKey: String) {
        Thread({
            val deadline = System.currentTimeMillis() + 10 * 60 * 1000
            while (System.currentTimeMillis() < deadline) {
                if (process !== started || !started.isAlive) return@Thread
                if (state == "ready") return@Thread
                try {
                    val connection = URL("http://127.0.0.1:$PORT/health").openConnection() as HttpURLConnection
                    connection.connectTimeout = 1500
                    connection.readTimeout = 1500
                    if (apiKey.isNotEmpty()) {
                        connection.setRequestProperty("Authorization", "Bearer $apiKey")
                    }
                    val code = connection.responseCode
                    connection.disconnect()
                    if (code == 200) {
                        markReady(started)
                        return@Thread
                    }
                } catch (_: Exception) {
                    // not listening yet
                }
                Thread.sleep(500)
            }
            if (process === started && state == "starting") {
                fail("Server did not become ready in time")
            }
        }, "llama-health").start()
    }

    private fun markReady(started: Process) {
        if (process !== started || state == "ready") return
        state = "ready"
        stateMessage = null
        emitStatus()
        LlamaService.instance?.update("llama.cpp ready")
    }

    private fun fail(message: String) {
        logLine("error: $message")
        state = "error"
        stateMessage = message
        emitStatus()
        LlamaService.instance?.update("llama.cpp error")
    }

    private fun describeStartFailure(e: Exception): String {
        val hint = when (e) {
            is IOException -> "The backend binary may not run on this device (wrong ABI or Android version); try the CPU backend. "
            else -> ""
        }
        return hint + (e.message ?: e.javaClass.simpleName)
    }

    private fun isGguf(file: File): Boolean {
        if (file.length() < 4) return false
        return try {
            file.inputStream().use { input ->
                val magic = ByteArray(4)
                if (input.read(magic) != 4) return false
                String(magic) == "GGUF"
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0)
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    private fun querySize(uri: Uri): Long {
        app.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getLong(0)
        }
        return -1
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, TAG_WAKE).apply {
            setReferenceCounted(false)
            acquire(6 * 60 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
            // ignore
        }
        wakeLock = null
    }

    private fun prefs() = app.getSharedPreferences("llama", Context.MODE_PRIVATE)

    private fun logLine(line: String) {
        if (line.isBlank()) return
        synchronized(logs) {
            logs.add(line)
            if (logs.size > 2000) logs.removeAt(0)
            pendingLogs.add(line)
        }
        if (!logFlushScheduled) {
            logFlushScheduled = true
            main.postDelayed({
                val batch = synchronized(logs) {
                    val copy = ArrayList(pendingLogs)
                    pendingLogs.clear()
                    logFlushScheduled = false
                    copy
                }
                emit(mapOf("type" to "log", "lines" to batch))
            }, 250)
        }
    }

    private fun emitStatus() {
        emit(
            mapOf(
                "type" to "state",
                "state" to state,
                "message" to stateMessage,
                "backend" to backend,
                "port" to PORT,
            )
        )
    }

    private fun emit(map: Map<String, Any?>) {
        main.post {
            try {
                sink?.success(map)
            } catch (_: Exception) {
                // sink detached
            }
        }
    }
}
