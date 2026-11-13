package com.roj.zen

import java.security.MessageDigest

/**
 * Whom the autofill believes, without any Android dependency (the
 * certificate lookup comes in through [SigningCertificateLookup], so the
 * rules have JVM tests of their own).
 *
 * Any app can put any `webDomain` on its views. A page's address is
 * believed only from a browser Zen knows, and only when the installed
 * package is signed with that browser's own certificate: an app installed
 * from elsewhere under a browser's package name (one the phone does not
 * have) is filled like any other app, by its package alone. Every other app
 * is matched by its package, and an entry that names the app's certificate
 * (`android://<hash>@package/`) only an app signed with it ([appSigning]).
 */

/** The installed packages' signing certificates, as Android knows them. */
fun interface SigningCertificateLookup {
    /**
     * Whether the installed [packageName] is signed with the certificate
     * whose SHA-256 digest is [sha256], or was before a key rotation it
     * proved (PackageManager.hasSigningCertificate). False when it is not
     * installed or Zen cannot see it.
     */
    fun isSignedWith(packageName: String, sha256: ByteArray): Boolean
}

/** Android 9: PackageManager.hasSigningCertificate and signingInfo. */
const val SIGNING_CERTIFICATE_MIN_SDK = 28

/**
 * The browsers whose report of a page's address Zen believes, each with
 * the SHA-256 digests of the certificates its own builds are signed with.
 * A browser with no digest here is not believed about pages (no digest
 * could be confirmed from two sources): it is filled like any other app.
 * The password setup lists the same browsers (`kKnownBrowsers` in
 * password_setup.dart), and the manifest's `<queries>` lets Zen see them.
 *
 * Each digest was read on 2026-11-12 from at least two of these and was
 * the same in each:
 * * [G] Google Password Manager's list of privileged browsers,
 *   https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json
 *   (Bitwarden ships the same file as fido2_privileged_google.json: not
 *   counted as a second source);
 * * [A] Android Password Store's trusted browsers,
 *   `TRUSTED_BROWSER_CERTIFICATE_HASH` in autofill-parser's
 *   FeatureAndTrustDetection.kt (base64 there, the same digest);
 * * [M] the maker's own Digital Asset Links file,
 *   `https://<site>/.well-known/assetlinks.json` of accounts.firefox.com,
 *   brave.com, duckduckgo.com and www.opera.com;
 * * [D] Mozilla's page on Fenix's signing certificates,
 *   https://firefox-source-docs.mozilla.org/mobile/android/fenix/certificates.html;
 * * [F] the signer in F-Droid's repository index (index-v2.json of
 *   f-droid.org/repo and f-droid.org/archive) or in the Guardian Project's
 *   repository, through which the Tor Project ships Tor Browser
 *   (guardianproject.info/fdroid/repo). The F-Droid builds below declare no
 *   developer's key in fdroiddata: they are signed with F-Droid's key;
 * * [B] Bitwarden's community list of privileged browsers,
 *   fido2_privileged_community.json in bitwarden/android;
 * * [R] IronFox's README (gitlab.com/ironfox-oss/IronFox), "SHA-256 Hash of
 *   Signing Certificate".
 *
 * Not believed, with only one source: Chromium (`org.chromium.chrome`, [G]
 * alone, with the key GrapheneOS's Vanadium is signed with), Samsung
 * Internet ([G] alone), Kiwi ([A] alone). Left out for the same reason: a
 * second key of Chrome Beta and Chrome Dev ([G] alone), the DivestOS build
 * of Mull ([A] alone), a third key of DuckDuckGo ([M] alone).
 */
val autofillBrowsers: Map<String, List<String>> = mapOf(
    // Chrome [G, A].
    "com.android.chrome" to listOf(
        "F0:FD:6C:5B:41:0F:25:CB:25:C3:B5:33:46:C8:97:2F:AE:30:F8:EE:74:11:DF:91:04:80:AD:6B:2D:60:DB:83",
    ),
    // Chrome Beta [G, A].
    "com.chrome.beta" to listOf(
        "DA:63:3D:34:B6:9E:63:AE:21:03:B4:9D:53:CE:05:2F:C5:F7:F3:C5:3A:AB:94:FD:C2:A2:08:BD:FD:14:24:9C",
    ),
    // Chrome Dev [G, A].
    "com.chrome.dev" to listOf(
        "90:44:EE:5F:EE:4B:BC:5E:21:DD:44:66:54:31:C4:EB:1F:1F:71:A3:27:16:A0:BC:92:7B:CB:B3:92:33:CA:BF",
    ),
    // Chrome Canary [G, A].
    "com.chrome.canary" to listOf(
        "20:19:DF:A1:FB:23:EF:BF:70:C5:BC:D1:44:3C:5B:EA:B0:4F:3F:2F:F4:36:6E:9A:C1:E3:45:76:39:A2:4C:FC",
    ),
    // Chromium: no confirmed key (builds by many people under this name).
    "org.chromium.chrome" to listOf(),
    // Brave [G, A, M].
    "com.brave.browser" to listOf(
        "9C:2D:B7:05:13:51:5F:DB:FB:BC:58:5B:3E:DF:3D:71:23:D4:DC:67:C9:4F:FD:30:63:61:C1:D7:9B:BF:18:AC",
    ),
    // Vivaldi [G, A].
    "com.vivaldi.browser" to listOf(
        "E8:A7:85:44:65:5B:A8:C0:98:17:F7:32:76:8F:56:89:B1:66:2E:C4:B2:BC:5A:0B:C0:EC:13:8D:33:CA:3D:1E",
    ),
    // Edge [G, A].
    "com.microsoft.emmx" to listOf(
        "01:E1:99:97:10:A8:2C:27:49:B4:D5:0C:44:5D:C8:5D:67:0B:61:36:08:9D:0A:76:6A:73:82:7C:82:A1:EA:C9",
    ),
    // Samsung Internet: no second source.
    "com.sec.android.app.sbrowser" to listOf(),
    // Opera [G, M].
    "com.opera.browser" to listOf(
        "5D:6A:FB:F8:7F:65:2A:F0:46:47:AD:A0:DF:63:4C:F2:23:70:90:0B:16:4B:09:D5:0B:D2:3A:A2:CB:52:85:B8",
    ),
    // Kiwi: no second source.
    "com.kiwibrowser.browser" to listOf(),
    // Firefox and Firefox Beta [G, A, M].
    "org.mozilla.firefox" to listOf(
        "A7:8B:62:A5:16:5B:44:94:B2:FE:AD:9E:76:A2:80:D2:2D:93:7F:EE:62:51:AE:CE:59:94:46:B2:EA:31:9B:04",
    ),
    "org.mozilla.firefox_beta" to listOf(
        "A7:8B:62:A5:16:5B:44:94:B2:FE:AD:9E:76:A2:80:D2:2D:93:7F:EE:62:51:AE:CE:59:94:46:B2:EA:31:9B:04",
    ),
    // Firefox Nightly (Fenix's production key) [G, A, M, D].
    "org.mozilla.fenix" to listOf(
        "50:04:77:90:88:E7:F9:88:D5:BC:5C:C5:F8:79:8F:EB:F4:F8:CD:08:4A:1B:2A:46:EF:D4:C8:EE:4A:EA:F2:11",
    ),
    // Firefox Focus and Klar [G, A].
    "org.mozilla.focus" to listOf(
        "62:03:A4:73:BE:36:D6:4E:E3:7F:87:FA:50:0E:DB:C7:9E:AB:93:06:10:AB:9B:9F:A4:CA:7D:5C:1F:1B:4F:FC",
    ),
    "org.mozilla.klar" to listOf(
        "62:03:A4:73:BE:36:D6:4E:E3:7F:87:FA:50:0E:DB:C7:9E:AB:93:06:10:AB:9B:9F:A4:CA:7D:5C:1F:1B:4F:FC",
    ),
    // Tor Browser [A, F: the Guardian Project's repository].
    "org.torproject.torbrowser" to listOf(
        "20:06:1F:04:5E:73:7C:67:37:5C:17:79:4C:FE:DB:43:6A:03:CE:C6:BA:CB:7C:B9:F9:66:42:20:5C:A2:CE:C8",
    ),
    // Mull as F-Droid built it (no longer updated) [A, F: archive].
    "us.spotco.fennec_dos" to listOf(
        "FF:81:F5:BE:56:39:65:94:EE:E7:0F:EF:28:32:25:6E:15:21:41:22:E2:BA:9C:ED:D2:60:05:FF:D4:BC:AA:A8",
    ),
    // Fennec, F-Droid's build of Firefox [A, B, F].
    "org.mozilla.fennec_fdroid" to listOf(
        "06:66:53:58:EF:D8:BA:05:BE:23:6A:47:A1:2C:B0:95:8D:7D:75:DD:93:9D:77:C2:B3:1F:53:98:53:7E:BD:C5",
    ),
    // IronFox, signed by its developers [B, R].
    "org.ironfoxoss.ironfox" to listOf(
        "C5:E2:91:B5:A5:71:F9:C8:CD:9A:97:99:C2:C9:4E:02:EC:97:03:94:88:93:F2:CA:75:6D:67:B9:42:04:F9:04",
    ),
    // DuckDuckGo: from Google Play [G, A, M] and as F-Droid builds it [A, F].
    "com.duckduckgo.mobile.android" to listOf(
        "BB:7B:B3:1C:57:3C:46:A1:DA:7F:C5:C5:28:A6:AC:F4:32:10:84:56:FE:EC:50:81:0C:7F:33:69:4E:B3:D2:D4",
        "F0:70:7D:02:1C:0B:F3:E6:F8:DC:C1:1B:A3:F5:70:04:25:D5:97:DC:A3:01:A3:1E:21:05:56:93:4E:BB:1B:0A",
    ),
)

/** A fingerprint as `AB:CD:…` (32 bytes) in bytes; null when it is not one. */
fun sha256Fingerprint(text: String): ByteArray? {
    val parts = text.split(':')
    if (parts.size != 32 || parts.any { it.length != 2 }) {
        return null
    }
    return try {
        ByteArray(32) { parts[it].toInt(16).toByte() }
    } catch (_: NumberFormatException) {
        null
    }
}

/** Whether an installed browser is the one its package name says. */
enum class BrowserSignature {
    /** Signed with its maker's certificate: believed about the page. */
    MAKER,

    /** Signed with another certificate: filled like any other app. */
    OTHER,

    /** Zen has no confirmed certificate of it (or cannot check): like any other app. */
    UNCONFIRMED,
}

/**
 * [packageName]'s signature as far as the autofill goes: [BrowserSignature.MAKER]
 * only for a browser of [autofillBrowsers] signed with one of its
 * certificates there. Before Android 9 ([sdkInt]) no certificate can be
 * checked this way: never the maker then.
 */
fun browserSignature(
    packageName: String,
    lookup: SigningCertificateLookup,
    sdkInt: Int,
): BrowserSignature {
    val pins = autofillBrowsers[packageName].orEmpty().mapNotNull { sha256Fingerprint(it) }
    if (pins.isEmpty() || sdkInt < SIGNING_CERTIFICATE_MIN_SDK) {
        return BrowserSignature.UNCONFIRMED
    }
    val signed = pins.any { pin ->
        try {
            lookup.isSignedWith(packageName, pin)
        } catch (_: Exception) {
            false
        }
    }
    return if (signed) BrowserSignature.MAKER else BrowserSignature.OTHER
}

/** A page's address the autofill matches by. */
class AutofillWebOrigin(val domain: String, val scheme: String?)

/**
 * The page [domain] (with its [scheme]) reported in the app [packageName],
 * when Zen may match by it: only in a browser of [autofillBrowsers] signed
 * with its maker's certificate ([browserSignature]), and only a plausible
 * host. Null otherwise: the app is matched by its package.
 */
fun trustedWebOrigin(
    packageName: String,
    domain: String?,
    scheme: String?,
    lookup: SigningCertificateLookup,
    sdkInt: Int,
): AutofillWebOrigin? {
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
    if (browserSignature(packageName, lookup, sdkInt) != BrowserSignature.MAKER) {
        return null
    }
    return AutofillWebOrigin(host, cleanScheme)
}

/**
 * What the picker gets about the certificates of the app that asks: the
 * SHA-256 and SHA-512 digests (lower-case hex) of every certificate it is
 * signed with or proved it rotated from ([digests]), to match the entries
 * that name one (`android://<hash>@package/`, as Chrome exports them: the
 * certificate's SHA-512 in base64); and the SHA-512 of the one it is signed
 * with now ([current]), named in a new entry saved for it. [current] is
 * null for an app signed by several signers at once.
 */
class AppSigning(val digests: List<String>, val current: String?)

private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

private fun digest(algorithm: String, bytes: ByteArray): String =
    hex(MessageDigest.getInstance(algorithm).digest(bytes))

/**
 * [AppSigning] of the certificates (DER) an app reported: [history] in the
 * order of its rotation, the original first and the current one last; or,
 * for an app with several signers at once ([multipleSigners]), all of them,
 * none current. Null when there is none.
 */
fun appSigning(history: List<ByteArray>, multipleSigners: Boolean): AppSigning? {
    if (history.isEmpty()) {
        return null
    }
    val digests = history.flatMap { listOf(digest("SHA-256", it), digest("SHA-512", it)) }.distinct()
    val current = if (multipleSigners) null else digest("SHA-512", history.last())
    return AppSigning(digests, current)
}
