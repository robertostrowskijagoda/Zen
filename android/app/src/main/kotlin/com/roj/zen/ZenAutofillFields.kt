package com.roj.zen

/**
 * Which fields of a form the autofill fills, without any Android dependency
 * (ZenAutofillService reads the form's views and hands them here, so the
 * rules have JVM tests of their own).
 *
 * Only a login form is filled: exactly one field that says it takes the
 * current password, and at most one login field before it; or, for the
 * first step of a login in two steps, no password field and exactly one
 * field that says it is the login. A field is taken for what it says it is,
 * in this order: the app's autofill hints, then the web page's
 * `autocomplete` and `type`, then the keyboard type of a native field. A
 * hint that says nothing about the field ("off", a section name) is passed
 * over; a field that says it is something else (a new password, a one-time
 * code, a search, a phone number) is never filled; a form with two password
 * fields (signing up, changing a password) is not filled at all.
 */

/** What a field is, as far as filling a login goes. */
enum class AutofillRole {
    /** The current password. */
    PASSWORD,

    /** The login: said so by a hint, `autocomplete`, or an e-mail type. */
    USERNAME,

    /** A plain text field whose name says login, user or mail. */
    LIKELY_USERNAME,

    /** Anything else: never filled. */
    NONE,
}

/**
 * One text field of a form, as the system reported it. [index] is its place
 * in the order the views were read (the order on the screen).
 */
class AutofillField(
    val index: Int,
    val hints: List<String> = emptyList(),
    val inputType: Int = 0,
    val htmlTag: String? = null,
    val htmlAttributes: List<Pair<String, String>> = emptyList(),
    /** The view's resource name, its hint text, the page's name and id. */
    val words: List<String> = emptyList(),
    val webDomain: String? = null,
    val webScheme: String? = null,
)

/**
 * The fields of a login form to fill, by [AutofillField.index]. Either may
 * be missing (a login in two steps asks for one on each page), not both.
 */
class LoginFields(val username: Int?, val password: Int?) {
    init {
        require(username != null || password != null) { "no field to fill" }
    }
}

/** android.text.InputType, copied so the rules stay free of Android. */
internal object InputTypeBits {
    const val MASK_CLASS = 0x0000000f
    const val MASK_VARIATION = 0x00000ff0
    const val CLASS_TEXT = 0x00000001
    const val CLASS_NUMBER = 0x00000002
    const val NUMBER_PASSWORD = 0x00000010
    const val TEXT_NORMAL = 0x00000000
    const val TEXT_EMAIL_ADDRESS = 0x00000020
    const val TEXT_PASSWORD = 0x00000080
    const val TEXT_VISIBLE_PASSWORD = 0x00000090
    const val TEXT_WEB_EDIT_TEXT = 0x000000a0
    const val TEXT_WEB_EMAIL_ADDRESS = 0x000000d0
    const val TEXT_WEB_PASSWORD = 0x000000e0
}

// View.AUTOFILL_HINT_PASSWORD and the page's own word for it.
private val passwordHints = setOf("password", "current-password", "currentpassword")

// View.AUTOFILL_HINT_USERNAME, View.AUTOFILL_HINT_EMAIL_ADDRESS and the
// page's words for them.
private val usernameHints = setOf("username", "emailaddress", "email")

// The hints that name the login itself, not only an e-mail address: only
// these make a form without a password a login's first step.
private val loginHints = setOf("username")

// Hints that say nothing about what a field is: "off" and the words pages
// put there to keep browsers from filling, the page's `section-*` and
// `shipping`/`billing` groups, the `home`/`work`/`mobile`/`fax`/`pager` that
// go before a contact token, and `webauthn` (a passkey may sign in here too).
// Chrome copies a page's `autocomplete` into the hints, so these are common.
private val emptyHints = setOf(
    "off", "on", "nope", "no", "false", "true", "none",
    "shipping", "billing", "home", "work", "mobile", "fax", "pager",
    "webauthn",
)

// Hints that say a field is something else: the rest of View.AUTOFILL_HINT_*,
// androidx.autofill's HintConstants (new logins and passwords, one-time
// codes, names, addresses, phones, dates, cards) and the HTML `autocomplete`
// field names other than the login and the current password.
private val otherHints = setOf(
    // View.AUTOFILL_HINT_*
    "name", "phone", "postaladdress", "postalcode",
    // HintConstants
    "newusername", "newpassword", "wifipassword", "emailotpcode", "2faappotpcode",
    "addresscountry", "addressregion", "addresslocality", "streetaddress",
    "extendedaddress", "extendedpostalcode", "gender", "promocode", "upivpa",
    // HTML autocomplete
    "new-password", "one-time-code", "honorific-prefix", "given-name",
    "additional-name", "family-name", "honorific-suffix", "nickname",
    "organization-title", "organization", "street-address", "country",
    "country-name", "postal-code", "transaction-currency", "transaction-amount",
    "language", "bday", "sex", "url", "photo", "tel", "impp",
    // Not in a standard, but plain about it.
    "search",
)

// Families of [otherHints]: cc-number, tel-national, address-line1,
// bday-year, creditCardNumber, smsOTPCode1, personGivenName, phoneNumber,
// birthDateFull, giftCardPin, flightNumber.
private val otherHintPrefixes = listOf(
    "cc-", "tel-", "address-", "bday-",
    "creditcard", "smsotpcode", "person", "phone", "birthdate", "giftcard", "flight",
)

// Hints of a password field that is not the current password.
private val otherPasswordHints = setOf("new-password", "newpassword")

/** Words in a field's names that make a plain text field the login. */
private val usernameWords = listOf("user", "login", "mail", "nick", "konto")

/** Words that make a field something else whatever its other names say. */
private val otherWords = listOf("search", "szukaj", "query", "otp", "code", "kod")

private fun autocompleteTokens(field: AutofillField): List<String> =
    field.htmlAttributes
        .filter { it.first.equals("autocomplete", ignoreCase = true) }
        .flatMap { it.second.lowercase().split(' ', '\t', '\n') }
        .filter { it.isNotEmpty() }

private fun cleanHints(field: AutofillField): List<String> =
    field.hints.map { it.trim().lowercase() }.filter { it.isNotEmpty() }

/**
 * What one hint or `autocomplete` token says a field is; null when it says
 * nothing. A word no list knows says nothing on a web page (pages write
 * anything there, "chrome-off" or a random word, to keep browsers away) but
 * something else in an app, whose hints are named on purpose.
 */
private fun roleOfHint(hint: String, web: Boolean): AutofillRole? = when {
    hint in passwordHints -> AutofillRole.PASSWORD
    hint in usernameHints -> AutofillRole.USERNAME
    hint in emptyHints || hint.startsWith("section-") -> null
    hint in otherHints || otherHintPrefixes.any { hint.startsWith(it) } -> AutofillRole.NONE
    web -> null
    else -> AutofillRole.NONE
}

private fun htmlType(field: AutofillField): String =
    field.htmlAttributes
        .firstOrNull { it.first.equals("type", ignoreCase = true) }
        ?.second?.trim()?.lowercase() ?: ""

private fun namedLikeLogin(field: AutofillField): Boolean {
    val words = field.words.map { it.lowercase() }
    if (words.any { w -> otherWords.any { w.contains(it) } }) {
        return false
    }
    return words.any { w -> usernameWords.any { w.contains(it) } }
}

/** What [field] is ([AutofillRole]). */
fun autofillRole(field: AutofillField): AutofillRole {
    // 1. The app's own hints, when one of them says something: it said what
    // the field is, and a field it called something else is not guessed at.
    val web = field.htmlTag != null
    val hintRoles = cleanHints(field).mapNotNull { roleOfHint(it, web) }
    when {
        AutofillRole.PASSWORD in hintRoles -> return AutofillRole.PASSWORD
        AutofillRole.USERNAME in hintRoles -> return AutofillRole.USERNAME
        AutofillRole.NONE in hintRoles -> return AutofillRole.NONE
    }
    // 2. A web page's input: its autocomplete and type.
    if (field.htmlTag != null) {
        if (!field.htmlTag.equals("input", ignoreCase = true)) {
            return AutofillRole.NONE
        }
        val tokenRoles = autocompleteTokens(field).mapNotNull { roleOfHint(it, web = true) }
        val type = htmlType(field)
        return when {
            AutofillRole.NONE in tokenRoles -> AutofillRole.NONE
            type == "password" || AutofillRole.PASSWORD in tokenRoles -> AutofillRole.PASSWORD
            type == "email" || AutofillRole.USERNAME in tokenRoles -> AutofillRole.USERNAME
            (type == "" || type == "text") && namedLikeLogin(field) -> AutofillRole.LIKELY_USERNAME
            else -> AutofillRole.NONE
        }
    }
    // 3. A native field: its keyboard type.
    if ((field.inputType and InputTypeBits.MASK_CLASS) != InputTypeBits.CLASS_TEXT) {
        return AutofillRole.NONE
    }
    return when (field.inputType and InputTypeBits.MASK_VARIATION) {
        InputTypeBits.TEXT_PASSWORD,
        InputTypeBits.TEXT_VISIBLE_PASSWORD,
        InputTypeBits.TEXT_WEB_PASSWORD -> AutofillRole.PASSWORD
        InputTypeBits.TEXT_EMAIL_ADDRESS,
        InputTypeBits.TEXT_WEB_EMAIL_ADDRESS -> AutofillRole.USERNAME
        InputTypeBits.TEXT_NORMAL,
        InputTypeBits.TEXT_WEB_EDIT_TEXT ->
            if (namedLikeLogin(field)) AutofillRole.LIKELY_USERNAME else AutofillRole.NONE
        else -> AutofillRole.NONE
    }
}

/**
 * Whether [field] takes a password of any kind (the current one, a new one,
 * a PIN): a form with two of them is no login, and a form with one is not
 * the first step of a login in two steps.
 */
private fun isPasswordInput(field: AutofillField, role: AutofillRole): Boolean {
    if (role == AutofillRole.PASSWORD) {
        return true
    }
    if ((cleanHints(field) + autocompleteTokens(field)).any { it in otherPasswordHints }) {
        return true
    }
    if (field.htmlTag != null) {
        return htmlType(field) == "password"
    }
    val variation = field.inputType and InputTypeBits.MASK_VARIATION
    return when (field.inputType and InputTypeBits.MASK_CLASS) {
        InputTypeBits.CLASS_TEXT ->
            variation == InputTypeBits.TEXT_PASSWORD ||
                variation == InputTypeBits.TEXT_VISIBLE_PASSWORD ||
                variation == InputTypeBits.TEXT_WEB_PASSWORD
        InputTypeBits.CLASS_NUMBER -> variation == InputTypeBits.NUMBER_PASSWORD
        else -> false
    }
}

/** Whether [field], a login field, says it is the login and not only an e-mail. */
private fun saysItIsTheLogin(field: AutofillField): Boolean =
    (cleanHints(field) + autocompleteTokens(field)).any { it in loginHints }

/**
 * The login form among [fields]: exactly one password field, and the login
 * field closest before it on the same page (one said to be the login before
 * one only named like it). Or, the first page of a login in two steps: no
 * password field at all and exactly one field that says it is the login
 * (its hint or `autocomplete` is `username`; an e-mail field alone is not
 * enough, or every newsletter's form would get the suggestion). Null
 * otherwise, two password fields among them: nothing is offered then.
 */
fun chooseLoginFields(fields: List<AutofillField>): LoginFields? {
    val roles = fields.associateWith { autofillRole(it) }
    val passwordInputs = fields.filter { isPasswordInput(it, roles.getValue(it)) }
    if (passwordInputs.isEmpty()) {
        val logins = fields.filter {
            roles[it] == AutofillRole.USERNAME && saysItIsTheLogin(it)
        }
        return logins.singleOrNull()?.let { LoginFields(it.index, null) }
    }
    if (passwordInputs.size != 1 || roles[passwordInputs.single()] != AutofillRole.PASSWORD) {
        return null
    }
    val password = passwordInputs.single()
    val before = fields.filter {
        it.index < password.index && it.webDomain == password.webDomain
    }
    val username = before.lastOrNull { roles[it] == AutofillRole.USERNAME }
        ?: before.lastOrNull { roles[it] == AutofillRole.LIKELY_USERNAME }
    return LoginFields(username?.index, password.index)
}

/**
 * The browsers whose report of a page's address Zen believes. Any app can
 * put any `webDomain` on its views; only a browser's is matched against the
 * saved pages, any other app is matched by its own package alone.
 */
val autofillBrowsers: Set<String> = setOf(
    "com.android.chrome",
    "com.chrome.beta",
    "com.chrome.dev",
    "com.chrome.canary",
    "org.chromium.chrome",
    "org.mozilla.firefox",
    "org.mozilla.firefox_beta",
    "org.mozilla.fenix",
    "org.mozilla.focus",
    "org.mozilla.klar",
    "org.torproject.torbrowser",
    "com.brave.browser",
    "com.microsoft.emmx",
    "com.sec.android.app.sbrowser",
    "com.vivaldi.browser",
    "com.opera.browser",
    "com.duckduckgo.mobile.android",
    "com.kiwibrowser.browser",
    "us.spotco.fennec_dos",
    "org.mozilla.fennec_fdroid",
    "org.ironfoxoss.ironfox",
)

/** A page's address the autofill matches by. */
class AutofillWebOrigin(val domain: String, val scheme: String?)

/**
 * The page [domain] (with its [scheme]) reported in the app [packageName],
 * when Zen may match by it: only in a browser of [autofillBrowsers], and
 * only a plausible host. Null otherwise: the app is matched by its package.
 */
fun trustedWebOrigin(packageName: String, domain: String?, scheme: String?): AutofillWebOrigin? {
    if (packageName !in autofillBrowsers) {
        return null
    }
    val host = domain?.trim() ?: return null
    if (host.isEmpty() || host.length > 253 || host.any { it.isWhitespace() || it == '/' || it == '@' }) {
        return null
    }
    // No scheme reported: the page counts as http (matched only with entries
    // that say http://). Any other scheme is no web page to match.
    val cleanScheme = scheme?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
    if (cleanScheme != null && cleanScheme != "https" && cleanScheme != "http") {
        return null
    }
    return AutofillWebOrigin(host, cleanScheme)
}
