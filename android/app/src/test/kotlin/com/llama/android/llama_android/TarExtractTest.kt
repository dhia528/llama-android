package com.llama.android.llama_android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.GZIPOutputStream

class TarExtractTest {
    @Test
    fun extractsIncludedFilesFromTopLevelDirectory() {
        val archive = archive(
            entry("pkg/llama-server", "BINARY", '0'),
            entry("pkg/lib/libggml.so", "LIB", '0'),
            entry("pkg/examples/chat", "TOOL", '0'),
        )
        val dest = Files.createTempDirectory("tar-extract").toFile()
        try {
            val extracted = TarExtract.extract(archive, dest, include = { it == "llama-server" || it.endsWith(".so") })
            assertTrue(extracted > 0)
            assertEquals("BINARY", File(dest, "llama-server").readText())
            assertEquals("LIB", File(dest, "lib/libggml.so").readText())
            assertFalse(File(dest, "examples/chat").exists())
            assertTrue(File(dest, "llama-server").canExecute())
        } finally {
            dest.deleteRecursively()
            archive.delete()
        }
    }

    @Test
    fun skipsTraversalAndLinks() {
        val archive = archive(
            entry("pkg/../escape.txt", "EVIL", '0'),
            entry("pkg/link", "", '2'),
            entry("pkg/ok.txt", "OK", '0'),
        )
        val dest = Files.createTempDirectory("tar-extract").toFile()
        try {
            TarExtract.extract(archive, dest, include = { true })
            assertFalse(File(dest.parentFile, "escape.txt").exists())
            assertFalse(File(dest, "link").exists())
            assertEquals("OK", File(dest, "ok.txt").readText())
        } finally {
            dest.deleteRecursively()
            archive.delete()
        }
    }

    private fun entry(name: String, content: String, type: Char): Pair<ByteArray, ByteArray> {
        val data = content.toByteArray()
        val header = ByteArray(512)
        name.toByteArray().copyInto(header, 0)
        "0000644\u0000".toByteArray().copyInto(header, 100)
        String.format("%011o", data.size).plus("\u0000").toByteArray().copyInto(header, 124)
        "0000000\u0000".toByteArray().copyInto(header, 136)
        "0000000\u0000".toByteArray().copyInto(header, 148)
        header[156] = type.code.toByte()
        "ustar\u000000".toByteArray().copyInto(header, 257)
        return header to data
    }

    private fun archive(vararg entries: Pair<ByteArray, ByteArray>): File {
        val bytes = ByteArrayOutputStream()
        GZIPOutputStream(bytes).use { out ->
            for ((header, data) in entries) {
                out.write(header)
                out.write(data)
                out.write(ByteArray((512 - data.size % 512) % 512))
            }
            out.write(ByteArray(1024))
        }
        return File.createTempFile("archive", ".tar.gz").apply { writeBytes(bytes.toByteArray()) }
    }
}
