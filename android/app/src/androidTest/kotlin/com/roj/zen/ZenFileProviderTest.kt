package com.roj.zen

import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/**
 * What ZenFileProvider hands to the share sheet (res/xml/file_paths.xml),
 * on a real Android: the installer copy and the QR sticker can be read
 * through their content address, nothing else can be given one.
 */
@RunWith(AndroidJUnit4::class)
class ZenFileProviderTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val authority = "${context.packageName}.zenshare"

    @Test
    fun sharedFilesAreReadThroughTheirContentAddress() {
        for (folder in listOf("shared_apk", "shared_sticker")) {
            val dir = File(context.cacheDir, folder).apply { mkdirs() }
            val file = File(dir, "probe.bin")
            val bytes = byteArrayOf(1, 2, 3, 42)
            file.writeBytes(bytes)
            try {
                val uri = FileProvider.getUriForFile(context, authority, file)
                assertEquals("content", uri.scheme)
                assertEquals(authority, uri.authority)
                val read = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                assertArrayEquals(bytes, read)
            } finally {
                file.delete()
            }
        }
    }

    /** [give] must refuse (JUnit 4.12, which the app's plugins bring, has no assertThrows). */
    private fun refused(give: () -> Any) {
        try {
            give()
        } catch (expected: IllegalArgumentException) {
            return
        }
        fail("a file outside the shared folders got a content address")
    }

    @Test
    fun nothingElseGetsAnAddress() {
        val secret = File(context.filesDir, "probe-secret.bin").apply { writeText("x") }
        try {
            refused { FileProvider.getUriForFile(context, authority, secret) }
            val elsewhere = File(context.cacheDir, "probe-elsewhere.bin").apply { writeText("x") }
            try {
                refused { FileProvider.getUriForFile(context, authority, elsewhere) }
            } finally {
                elsewhere.delete()
            }
        } finally {
            secret.delete()
        }
    }
}
