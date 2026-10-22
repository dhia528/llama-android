package com.llama.android.llama_android

import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.zip.GZIPInputStream

/**
 * Minimal streaming tar.gz extractor for llama.cpp release packages.
 *
 * Deliberately narrow: regular files and directories only, no links, no device
 * nodes, no ownership/mtime. Paths are stripped of their top-level directory and
 * must stay inside the destination. Only entries accepted by [include] are written.
 */
object TarExtract {
    private const val BLOCK = 512
    private const val MAX_EXTRACTED_BYTES = 2L * 1024 * 1024 * 1024
    private const val MAX_ENTRIES = 5000

    fun extract(
        archive: File,
        dest: File,
        include: (String) -> Boolean,
        onProgress: (Long) -> Unit = {},
    ): Long {
        var extracted = 0L
        var entries = 0
        var longName: String? = null

        dest.mkdirs()
        val destRoot = dest.canonicalFile
        BufferedInputStream(archive.inputStream(), 64 * 1024).use { raw ->
            GZIPInputStream(raw, 64 * 1024).use { input ->
                val header = ByteArray(BLOCK)
                while (true) {
                    if (!readFully(input, header)) break
                    if (header.all { it == 0.toByte() }) break // end of archive
                    if (++entries > MAX_ENTRIES) throw IOException("archive has too many entries")

                    var name = readString(header, 0, 100)
                    val prefix = readString(header, 345, 155).trim()
                    if (prefix.isNotEmpty()) name = "$prefix/$name"
                    longName?.let { name = it; longName = null }

                    val size = readOctal(header, 124, 12)
                    val type = header[156].toInt().toChar()

                    when (type) {
                        'L' -> { // GNU long name for the next entry
                            val bytes = readEntry(input, size)
                            longName = String(bytes, StandardCharsets.UTF_8).trimEnd('\u0000')
                            skipPadding(input, size)
                        }
                        'x', 'g' -> { // PAX metadata: ignored, paths in these archives fit in ustar fields
                            skipEntry(input, size)
                        }
                        '5' -> {
                            skipEntry(input, size)
                            val rel = stripTop(name)
                            if (rel != null) safePath(destRoot, rel)?.mkdirs()
                        }
                        '0', '\u0000', '7' -> {
                            val rel = stripTop(name)
                            if (rel != null && include(rel)) {
                                val target = safePath(destRoot, rel)
                                    ?: throw IOException("unsafe path in archive: $name")
                                target.parentFile?.mkdirs()
                                extracted += copyEntry(input, size, target)
                                if (extracted > MAX_EXTRACTED_BYTES) {
                                    throw IOException("archive expands beyond limit")
                                }
                                target.setExecutable(true, false)
                                onProgress(extracted)
                            } else {
                                skipEntry(input, size)
                            }
                        }
                        else -> skipEntry(input, size)
                    }
                }
            }
        }
        return extracted
    }

    private fun stripTop(name: String): String? {
        var n = name.trim()
        if (n.isEmpty() || n.startsWith("/") || n.contains('\\')) return null
        val slash = n.indexOf('/')
        if (slash < 0) return null
        n = n.substring(slash + 1)
        if (n.isEmpty()) return null
        val parts = n.split('/')
        if (parts.any { it.isEmpty() || it == "." || it == ".." }) return null
        return n
    }

    private fun safePath(root: File, rel: String): File? {
        val f = File(root, rel).canonicalFile
        return if (f == root || f.path.startsWith(root.path + File.separator)) f else null
    }

    private fun readString(buf: ByteArray, offset: Int, len: Int): String {
        var end = offset
        while (end < offset + len && buf[end] != 0.toByte()) end++
        return String(buf, offset, end - offset, StandardCharsets.UTF_8)
    }

    private fun readOctal(buf: ByteArray, offset: Int, len: Int): Long {
        val text = readString(buf, offset, len).trim()
        if (text.isEmpty()) return 0
        return try {
            text.toLong(8)
        } catch (_: NumberFormatException) {
            throw IOException("bad tar size field: $text")
        }
    }

    private fun readFully(input: InputStream, buf: ByteArray): Boolean {
        var read = 0
        while (read < buf.size) {
            val n = input.read(buf, read, buf.size - read)
            if (n < 0) {
                if (read == 0) return false
                throw IOException("truncated tar header")
            }
            read += n
        }
        return true
    }

    private fun readEntry(input: InputStream, size: Long): ByteArray {
        if (size > 4 * 1024 * 1024) throw IOException("tar metadata entry too large")
        val bytes = ByteArray(size.toInt())
        var read = 0
        while (read < bytes.size) {
            val n = input.read(bytes, read, bytes.size - read)
            if (n < 0) throw IOException("truncated tar entry")
            read += n
        }
        return bytes
    }

    private fun copyEntry(input: InputStream, size: Long, target: File): Long {
        FileOutputStream(target).use { out ->
            val buf = ByteArray(64 * 1024)
            var left = size
            while (left > 0) {
                val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                if (n < 0) throw IOException("truncated tar data")
                out.write(buf, 0, n)
                left -= n
            }
        }
        skipPadding(input, size)
        return size
    }

    private fun skipEntry(input: InputStream, size: Long) {
        skipExactly(input, size)
        skipPadding(input, size)
    }

    private fun skipPadding(input: InputStream, size: Long) {
        val pad = ((BLOCK - size % BLOCK) % BLOCK).toInt()
        skipExactly(input, pad.toLong())
    }

    private fun skipExactly(input: InputStream, count: Long) {
        var left = count
        val buf = ByteArray(64 * 1024)
        while (left > 0) {
            val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) throw IOException("truncated tar archive")
            left -= n
        }
    }
}
