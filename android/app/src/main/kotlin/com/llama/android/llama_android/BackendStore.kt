package com.llama.android.llama_android

import android.content.Context
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Downloads and unpacks the pinned llama.cpp Android release packages.
 *
 * Only the server executable and its shared libraries are kept, so the on-disk
 * footprint stays roughly the size of the compressed release.
 */
object BackendStore {
    data class Spec(
        val id: String,
        val url: String,
        val exeRel: String,
        val libRel: String,
    )

    val specs = listOf(
        Spec(
            id = "cpu",
            url = "https://github.com/ggml-org/llama.cpp/releases/download/b11798/llama-b11798-bin-android-arm64.tar.gz",
            exeRel = "llama-server",
            libRel = ".",
        ),
        Spec(
            id = "adreno",
            url = "https://github.com/ggml-org/llama.cpp/releases/download/b11798/llama-b11798-bin-android-arm64-snapdragon.tar.gz",
            exeRel = "bin/llama-server",
            libRel = "lib",
        ),
        // shortcut: Hexagon reuses the snapdragon archive (same 61 MB) in its own folder.
        // Share the package dir if download size becomes a problem.
        Spec(
            id = "hexagon",
            url = "https://github.com/ggml-org/llama.cpp/releases/download/b11798/llama-b11798-bin-android-arm64-snapdragon.tar.gz",
            exeRel = "bin/llama-server",
            libRel = "lib",
        ),
    )

    fun spec(id: String): Spec = specs.firstOrNull { it.id == id }
        ?: throw IllegalArgumentException("unknown backend: $id")

    fun dir(context: Context, id: String): File = File(context.filesDir, "backends/$id")

    fun executable(context: Context, id: String): File = File(dir(context, id), spec(id).exeRel)

    fun libraries(context: Context, id: String): File = File(dir(context, id), spec(id).libRel)

    fun installed(context: Context, id: String): Boolean = executable(context, id).isFile

    fun sizeOnDisk(context: Context, id: String): Long = folderSize(dir(context, id))

    fun delete(context: Context, id: String) {
        dir(context, id).deleteRecursively()
    }

    fun install(
        context: Context,
        id: String,
        onProgress: (received: Long, total: Long) -> Unit,
        onLog: (String) -> Unit,
    ) {
        val spec = spec(id)
        val cacheDir = File(context.cacheDir, "backends").apply { mkdirs() }
        val archive = File(cacheDir, "$id.tar.gz")
        val staging = File(context.filesDir, "backends/$id.tmp")
        staging.deleteRecursively()

        try {
            onLog("Downloading ${spec.url}")
            val (received, total) = download(spec.url, archive, onProgress)
            onLog("Downloaded ${received / (1024 * 1024)} MB" + if (total > 0) " of ${total / (1024 * 1024)} MB" else "")

            val extracted = TarExtract.extract(archive, staging, include = { rel ->
                rel == spec.exeRel ||
                    (rel.startsWith("lib/") || !rel.contains('/')) &&
                    rel.substringAfterLast('/').let { it.startsWith("lib") && it.endsWith(".so") }
            })

            if (!File(staging, spec.exeRel).isFile) {
                throw IOException("archive did not contain ${spec.exeRel}")
            }
            onLog("Extracted ${extracted / (1024 * 1024)} MB")

            val finalDir = dir(context, id)
            finalDir.deleteRecursively()
            if (!staging.renameTo(finalDir)) {
                staging.copyRecursively(finalDir, overwrite = true)
                staging.deleteRecursively()
            }
            onLog("Backend '$id' installed")
        } finally {
            archive.delete()
            staging.deleteRecursively()
        }
    }

    private fun download(url: String, target: File, onProgress: (Long, Long) -> Unit): Pair<Long, Long> {
        val connection = openAllowed(url)
        try {
            val total = connection.contentLengthLong
            if (total > 0) {
                val needed = total * 3 + 100L * 1024 * 1024
                val free = target.parentFile?.usableSpace ?: 0
                if (free > 0 && free < needed) {
                    throw IOException("Not enough free space: need about ${needed / (1024 * 1024)} MB")
                }
            }
            var received = 0L
            var lastReport = 0L
            target.outputStream().use { out ->
                connection.inputStream.use { input ->
                    val buf = ByteArray(128 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        received += n
                        if (received - lastReport > 1024 * 1024) {
                            lastReport = received
                            onProgress(received, total)
                        }
                    }
                }
            }
            if (total > 0 && received != total) {
                throw IOException("Incomplete download: $received of $total bytes")
            }
            return received to total
        } finally {
            connection.disconnect()
        }
    }

    /** Follows redirects manually so every hop is checked against the allowlist. */
    private fun openAllowed(rawUrl: String): HttpURLConnection {
        var url = URL(rawUrl)
        repeat(6) {
            val host = url.host.lowercase()
            val allowed = host == "github.com" ||
                host == "githubusercontent.com" ||
                host.endsWith(".githubusercontent.com")
            if (!allowed) throw IOException("Refusing download from $host")

            val connection = url.openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("User-Agent", "llama-android/1.0")
            val code = connection.responseCode
            if (code in 300..399) {
                val location = connection.getHeaderField("Location")
                    ?: throw IOException("redirect without Location")
                connection.disconnect()
                url = URL(url, location)
                return@repeat
            }
            if (code != 200) {
                connection.disconnect()
                throw IOException("HTTP $code while downloading from $host")
            }
            return connection
        }
        throw IOException("too many redirects")
    }

    private fun folderSize(file: File): Long {
        if (!file.exists()) return 0
        if (file.isFile) return file.length()
        return file.listFiles()?.sumOf { folderSize(it) } ?: 0
    }
}
