package com.roj.zen

import android.content.pm.PackageManager
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * What other apps may start in Zen, as the installed app says (the merged
 * manifest, libraries included): only the launcher entries and "Otwórz w
 * Zen" of Zen's own components; its file provider is never open to them.
 * A component made open by mistake (a library's default, a forgotten
 * `exported`) fails here.
 */
@RunWith(AndroidJUnit4::class)
class ExportedComponentsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** Zen's own components other apps may start. */
    private val open = setOf(
        "com.roj.zen.MainActivity",
        "com.roj.zen.LauncherDefault",
        "com.roj.zen.LauncherDisguise",
        "com.roj.zen.ZenOpenFileActivity",
    )

    @Suppress("DEPRECATION")
    private fun info() = context.packageManager.getPackageInfo(
        context.packageName,
        PackageManager.GET_ACTIVITIES or PackageManager.GET_SERVICES or
            PackageManager.GET_RECEIVERS or PackageManager.GET_PROVIDERS or
            (if (Build.VERSION.SDK_INT >= 24) PackageManager.MATCH_DISABLED_COMPONENTS else 0),
    )

    @Test
    fun onlyTheLauncherAndOpenWithAreOpenAmongZensOwn() {
        val info = info()
        val exported = buildList {
            info.activities?.filter { it.exported }?.forEach { add(it.name) }
            info.services?.filter { it.exported && it.permission == null }?.forEach { add(it.name) }
            info.receivers?.filter { it.exported && it.permission == null }?.forEach { add(it.name) }
        }.filter { it.startsWith("com.roj.zen.") }
        val unexpected = exported.filterNot { it in open }
        assertTrue("Open to other apps by mistake: $unexpected", unexpected.isEmpty())
        assertTrue(
            "The launcher entry must stay open",
            exported.any { it == "com.roj.zen.MainActivity" || it == "com.roj.zen.LauncherDefault" },
        )
    }

    @Test
    fun theAutofillIsBoundOnlyByTheSystemAndItsActivityIsClosed() {
        val info = info()
        val service = info.services?.firstOrNull { it.name == "com.roj.zen.ZenAutofillService" }
        assertTrue("ZenAutofillService is in the manifest", service != null)
        assertTrue(
            "Only the system may bind the autofill service",
            service!!.permission == "android.permission.BIND_AUTOFILL_SERVICE",
        )
        val activity = info.activities?.firstOrNull { it.name == "com.roj.zen.ZenAutofillActivity" }
        assertTrue("ZenAutofillActivity is in the manifest", activity != null)
        assertTrue("ZenAutofillActivity must not be exported", activity!!.exported.not())
    }

    @Test
    fun theFileProviderIsClosed() {
        val provider = info().providers?.firstOrNull { it.name == "com.roj.zen.ZenFileProvider" }
        assertTrue("ZenFileProvider is in the manifest", provider != null)
        assertTrue("ZenFileProvider must not be exported", provider!!.exported.not())
        assertTrue("It grants reading per file", provider.grantUriPermissions)
    }
}
