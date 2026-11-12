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

    private fun html(
        index: Int,
        vararg attributes: Pair<String, String>,
        domain: String? = "example.com",
        hints: List<String> = emptyList(),
    ) = AutofillField(
        index = index,
        hints = hints,
        htmlTag = "input",
        htmlAttributes = attributes.toList(),
        webDomain = domain,
        webScheme = "https",
    )

    /** A page's input as Chrome reports it: its `autocomplete` also as the hints. */
    private fun chrome(index: Int, type: String, autocomplete: String, name: String = "") =
        AutofillField(
            index = index,
            hints = autocomplete.split(' ').filter { it.isNotEmpty() },
            htmlTag = "input",
            htmlAttributes = listOf("type" to type, "name" to name),
            words = listOf(name).filter { it.isNotEmpty() },
            webDomain = "example.com",
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
    fun hintsThatSayNothingLeaveItToTheTypeOfTheField() {
        for (autocomplete in listOf(
            "off", "on", "nope", "false", "none", "OFF", "section-login", "section-",
            "webauthn", "shipping", "billing", "chrome-off", "section-a current-password webauthn",
        )) {
            assertEquals(
                autocomplete,
                AutofillRole.PASSWORD,
                autofillRole(chrome(0, "password", autocomplete)),
            )
        }
        // An empty hint is no hint.
        assertEquals(
            AutofillRole.PASSWORD,
            autofillRole(AutofillField(0, hints = listOf(" "), inputType = password)),
        )
        assertEquals(
            AutofillRole.PASSWORD,
            autofillRole(AutofillField(0, hints = listOf("off"), inputType = password)),
        )
        assertEquals(
            AutofillRole.LIKELY_USERNAME,
            autofillRole(chrome(0, "text", "off", name = "login")),
        )
        assertEquals(
            AutofillRole.USERNAME,
            autofillRole(chrome(0, "email", "nope")),
        )
    }

    @Test
    fun aBankLoginWithAutocompleteOffIsFilled() {
        val chosen = chooseLoginFields(
            listOf(
                chrome(0, "text", "off", name = "login"),
                chrome(1, "password", "off", name = "pass"),
            ),
        )
        assertNotNull(chosen)
        assertEquals(0, chosen!!.username)
        assertEquals(1, chosen.password)
    }

    @Test
    fun hintsThatSayTheFieldIsSomethingElseStillKeepItEmpty() {
        for (autocomplete in listOf(
            "new-password", "one-time-code", "cc-csc", "cc-number", "tel", "tel-national",
            "name", "given-name", "nickname", "street-address", "address-line1",
            "postal-code", "bday-year", "organization", "url", "search",
            "section-x billing cc-csc", "work tel", "newPassword", "smsOTPCode",
        )) {
            assertEquals(
                autocomplete,
                AutofillRole.NONE,
                autofillRole(chrome(0, "password", autocomplete)),
            )
        }
        // The same words from an app's own hints.
        for (hint in listOf(
            "phone", "name", "postalAddress", "postalCode", "creditCardNumber",
            "creditCardSecurityCode", "creditCardExpirationDate", "newUsername",
            "newPassword", "smsOTPCode", "smsOTPCode3", "emailOTPCode", "2faAppOTPCode",
            "personName", "phoneNumber", "birthDateFull", "wifiPassword", "giftCardPin",
        )) {
            assertEquals(
                hint,
                AutofillRole.NONE,
                autofillRole(AutofillField(0, hints = listOf(hint), inputType = password)),
            )
        }
        // An app names its hints on purpose: one no list knows is something else.
        assertEquals(
            AutofillRole.NONE,
            autofillRole(AutofillField(0, hints = listOf("loyaltyNumber"), inputType = password)),
        )
    }

    @Test
    fun aPagesAutocompleteSaysSomethingElseAlsoWithoutHints() {
        // A browser that puts `autocomplete` only among the attributes.
        assertEquals(
            AutofillRole.NONE,
            autofillRole(html(0, "type" to "password", "autocomplete" to "cc-csc")),
        )
        assertEquals(
            AutofillRole.NONE,
            autofillRole(html(0, "type" to "text", "autocomplete" to "tel", "name" to "login")),
        )
        assertEquals(
            AutofillRole.PASSWORD,
            autofillRole(html(0, "type" to "password", "autocomplete" to "off")),
        )
    }

    @Test
    fun theFirstStepOfATwoStepLoginFillsTheLoginAlone() {
        // Google's first page: autocomplete="username webauthn" on an e-mail input.
        val chosen = chooseLoginFields(
            listOf(
                chrome(0, "email", "username webauthn", name = "identifier"),
                html(1, "type" to "checkbox"),
            ),
        )
        assertNotNull(chosen)
        assertEquals(0, chosen!!.username)
        assertNull(chosen.password)
        // The same from an app's hint, and from a page's attribute alone.
        assertEquals(
            0,
            chooseLoginFields(listOf(AutofillField(0, hints = listOf("username"), inputType = text)))!!.username,
        )
        assertEquals(
            0,
            chooseLoginFields(listOf(html(0, "type" to "text", "autocomplete" to "username")))!!.username,
        )
    }

    @Test
    fun anEmailFieldAloneIsNoLogin() {
        // A newsletter's form: an e-mail address, nothing says it is a login.
        assertNull(chooseLoginFields(listOf(html(0, "type" to "email"))))
        assertNull(chooseLoginFields(listOf(chrome(0, "email", "email"))))
        assertNull(chooseLoginFields(listOf(AutofillField(0, hints = listOf("emailAddress")))))
        assertNull(chooseLoginFields(listOf(AutofillField(0, inputType = email))))
        assertNull(chooseLoginFields(listOf(chrome(0, "text", "off", name = "login"))))
        // Two fields that both say they are the login: which one is unclear.
        assertNull(
            chooseLoginFields(
                listOf(chrome(0, "text", "username"), chrome(1, "email", "username")),
            ),
        )
    }

    @Test
    fun aLoginBesideAnyOtherPasswordIsNotAFirstStep() {
        // Signing up: the login and a new password.
        assertNull(
            chooseLoginFields(
                listOf(chrome(0, "text", "username"), chrome(1, "password", "new-password")),
            ),
        )
        // A login and a PIN.
        assertNull(
            chooseLoginFields(
                listOf(
                    AutofillField(0, hints = listOf("username"), inputType = text),
                    AutofillField(
                        1,
                        inputType = InputTypeBits.CLASS_NUMBER or InputTypeBits.NUMBER_PASSWORD,
                    ),
                ),
            ),
        )
    }

    @Test
    fun theSecondStepOfATwoStepLoginFillsThePasswordAlone() {
        val chosen = chooseLoginFields(
            listOf(
                chrome(0, "password", "current-password"),
                html(1, "type" to "checkbox"),
            ),
        )
        assertNotNull(chosen)
        assertNull(chosen!!.username)
        assertEquals(0, chosen.password)
        assertEquals(1, chooseLoginFields(listOf(AutofillField(1, inputType = password)))!!.password)
    }

    @Test
    fun formsWithTwoPasswordFieldsStayEmpty() {
        // Changing a password: the current one beside the new one.
        assertNull(
            chooseLoginFields(
                listOf(
                    chrome(0, "password", "current-password"),
                    chrome(1, "password", "new-password"),
                    chrome(2, "password", "new-password"),
                ),
            ),
        )
        // The same without hints, as a bank writes it.
        assertNull(
            chooseLoginFields(
                listOf(
                    chrome(0, "text", "off", name = "login"),
                    chrome(1, "password", "off"),
                    chrome(2, "password", "off"),
                ),
            ),
        )
        assertNull(
            chooseLoginFields(
                listOf(
                    AutofillField(0, hints = listOf("password"), inputType = password),
                    AutofillField(1, hints = listOf("newPassword"), inputType = password),
                ),
            ),
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun aLoginFormFillsAtLeastOneField() {
        LoginFields(null, null)
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
