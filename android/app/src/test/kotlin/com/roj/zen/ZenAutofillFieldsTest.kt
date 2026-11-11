package com.roj.zen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which fields of another app's form Zen fills (ZenAutofillFields.kt):
 * only a login form, a field only for what it says it is, and a page's
 * address only from a known browser.
 */
class ZenAutofillFieldsTest {
    private val text = InputTypeBits.CLASS_TEXT
    private val password = InputTypeBits.CLASS_TEXT or InputTypeBits.TEXT_PASSWORD
    private val email = InputTypeBits.CLASS_TEXT or InputTypeBits.TEXT_EMAIL_ADDRESS

    private fun html(index: Int, vararg attributes: Pair<String, String>, domain: String? = "example.com") =
        AutofillField(
            index = index,
            htmlTag = "input",
            htmlAttributes = attributes.toList(),
            webDomain = domain,
            webScheme = "https",
        )

    @Test
    fun aNativeLoginFormFillsTheLoginAndThePassword() {
        val fields = listOf(
            AutofillField(0, inputType = text, words = listOf("search_box")),
            AutofillField(1, inputType = email),
            AutofillField(2, inputType = password),
        )
        val chosen = chooseLoginFields(fields)
        assertNotNull(chosen)
        assertEquals(1, chosen!!.username)
        assertEquals(2, chosen.password)
    }

    @Test
    fun hintsComeFirstAndAFieldCalledSomethingElseIsNeverFilled() {
        assertEquals(
            AutofillRole.PASSWORD,
            autofillRole(AutofillField(0, hints = listOf("password"), inputType = text)),
        )
        assertEquals(
            AutofillRole.NONE,
            autofillRole(AutofillField(0, hints = listOf("phone"), inputType = password)),
        )
        assertEquals(
            AutofillRole.USERNAME,
            autofillRole(AutofillField(0, hints = listOf("emailAddress"))),
        )
    }

    @Test
    fun aPagesNewPasswordOrOneTimeCodeIsNotAPasswordToFill() {
        assertEquals(
            AutofillRole.NONE,
            autofillRole(html(0, "type" to "password", "autocomplete" to "new-password")),
        )
        assertEquals(
            AutofillRole.NONE,
            autofillRole(html(0, "type" to "text", "autocomplete" to "one-time-code")),
        )
        assertEquals(
            AutofillRole.PASSWORD,
            autofillRole(html(0, "type" to "password")),
        )
        assertEquals(
            AutofillRole.LIKELY_USERNAME,
            autofillRole(
                AutofillField(
                    0,
                    htmlTag = "input",
                    htmlAttributes = listOf("type" to "text"),
                    words = listOf("login"),
                ),
            ),
        )
        assertEquals(AutofillRole.NONE, autofillRole(html(0, "type" to "search")))
        assertEquals(AutofillRole.NONE, autofillRole(html(0, "type" to "hidden")))
    }

    @Test
    fun twoPasswordFieldsOrNoneOfferNothing() {
        assertNull(chooseLoginFields(listOf(AutofillField(0, inputType = email))))
        assertNull(
            chooseLoginFields(
                listOf(
                    AutofillField(0, inputType = password),
                    AutofillField(1, inputType = password),
                ),
            ),
        )
    }

    @Test
    fun theLoginComesFromTheSamePageAsThePassword() {
        val fields = listOf(
            html(0, "type" to "email", domain = "ads.example.net"),
            html(1, "type" to "password"),
        )
        val chosen = chooseLoginFields(fields)
        assertNotNull(chosen)
        assertNull(chosen!!.username)
        assertEquals(1, chosen.password)
    }

    @Test
    fun aPagesAddressCountsOnlyInAKnownBrowser() {
        assertNull(trustedWebOrigin("com.evil.app", "bank.example.com", "https"))
        val chrome = trustedWebOrigin("com.android.chrome", "bank.example.com", "https")
        assertEquals("bank.example.com", chrome!!.domain)
        assertEquals("https", chrome.scheme)
        assertNull(trustedWebOrigin("com.android.chrome", "a b", "https"))
        assertNull(trustedWebOrigin("com.android.chrome", "", "https"))
        assertNull(trustedWebOrigin("com.android.chrome", "example.com", "file"))
        // No scheme reported: matched as http, never with https entries.
        assertNull(trustedWebOrigin("org.mozilla.firefox", "example.com", null)!!.scheme)
    }
}
