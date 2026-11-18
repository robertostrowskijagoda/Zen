package com.roj.zen

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.BlendMode
import android.graphics.drawable.Icon
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.InlinePresentation
import android.service.autofill.Presentations
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.util.Log
import android.view.View
import android.view.autofill.AutofillId
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi

/**
 * Zen as Android's autofill service: off until the person picks Zen in
 * Android's settings ("Wypełnianie w innych aplikacjach" in "Hasła" opens
 * that page). Only the system binds it (BIND_AUTOFILL_SERVICE).
 *
 * A login form in another app or a browser gets one suggestion, "Zen /
 * Unlock Zen" (in the keyboard when it shows suggestions, in a drop-down
 * otherwise), that carries no login and no password: nothing is read from disk
 * here and no password exists on this side. Tapping it starts
 * [ZenAutofillActivity] (the authentication of the suggestion), which
 * brings up Zen; the person unlocks it, confirms who they are and picks
 * an entry, and only that entry comes back to fill the form.
 *
 * What the request carries to that activity is fixed here, in an immutable
 * PendingIntent the requesting app cannot change: the app's package as the
 * system reports it, the page's address only from a known browser signed
 * with its maker's certificate ([trustedWebOrigin]; in Android's
 * compatibility mode only from its address bar, [compatibilityWebOrigin]),
 * and the ids of the fields the form has (the login,
 * the password, or both: [chooseLoginFields]). Each new suggestion
 * cancels the one before it (one request code, FLAG_CANCEL_CURRENT).
 *
 * Saving logins typed elsewhere is not offered in this version: the
 * response declares no SaveInfo, so Android never asks to save into Zen.
 *
 * Nothing about the app, the page or the fields goes to the log: only the
 * kind of an error.
 */
@RequiresApi(Build.VERSION_CODES.O)
class ZenAutofillService : AutofillService() {

    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback,
    ) {
        val response = try {
            respond(request)
        } catch (error: Exception) {
            Log.w(TAG, "Reading a form to fill failed: ${error.javaClass.simpleName}")
            null
        }
        // Null: nothing to offer for this form.
        callback.onSuccess(response)
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        // Never asked for (no SaveInfo is declared); refused without a word.
        callback.onFailure(null)
    }

    private fun respond(request: FillRequest): FillResponse? {
        // Android 9+: the system checks the app's package on the structure
        // (an app could name another one before) and reports the page's
        // scheme. Earlier versions get no suggestion.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return null
        }
        val structure = request.fillContexts.lastOrNull()?.structure ?: return null
        val client = structure.activityComponent?.packageName ?: return null
        if (client == packageName) {
            return null
        }
        val form = FormReader()
        for (i in 0 until structure.windowNodeCount) {
            form.read(structure.getWindowNodeAt(i).rootViewNode, null, null, 0)
        }
        val chosen = chooseLoginFields(form.fields) ?: return null
        val passwordId = chosen.password?.let { form.ids[it] }
        val usernameId = chosen.username?.let { form.ids[it] }
        // The page of the password field, or of the login when the form
        // asks for the login alone (the first step of two).
        val anchor = form.fields[chosen.password ?: chosen.username ?: return null]
        val certificates = PackageSigningCertificates(packageManager)
        // In compatibility mode (a browser that hands no form to the
        // service itself, res/xml/zen_autofill_service.xml) the form comes
        // from the browser's accessibility tree, where the page makes the
        // nodes: no web domain on them counts, only the address bar's.
        val compatibility = (request.flags and FillRequest.FLAG_COMPATIBILITY_MODE_REQUEST) != 0
        val web = if (compatibility) {
            compatibilityWebOrigin(client, addressBars(structure, client), certificates, Build.VERSION.SDK_INT)
        } else {
            trustedWebOrigin(client, anchor.webDomain, anchor.webScheme, certificates, Build.VERSION.SDK_INT)
        }

        val intent = Intent(this, ZenAutofillActivity::class.java).apply {
            putExtra(ZenAutofillActivity.EXTRA_PACKAGE, client)
            if (web != null) {
                putExtra(ZenAutofillActivity.EXTRA_WEB_DOMAIN, web.domain)
                web.scheme?.let { putExtra(ZenAutofillActivity.EXTRA_WEB_SCHEME, it) }
            }
            passwordId?.let { putExtra(ZenAutofillActivity.EXTRA_PASSWORD_ID, it) }
            usernameId?.let { putExtra(ZenAutofillActivity.EXTRA_USERNAME_ID, it) }
        }
        val sender = PendingIntent.getActivity(
            this,
            AUTH_REQUEST,
            intent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        ).intentSender

        // No values: only which fields the entry will fill.
        val ids = listOfNotNull(usernameId, passwordId)
        // In the keyboard when it shows suggestions (Android 11+), in the
        // drop-down otherwise.
        val inline = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            inlinePresentation(request)
        } else {
            null
        }
        val dataset = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val presentations = Presentations.Builder()
                .setMenuPresentation(presentation())
                .apply { inline?.let { setInlinePresentation(it) } }
                .build()
            Dataset.Builder(presentations).apply {
                ids.forEach { setField(it, null) }
                setAuthentication(sender)
            }.build()
        } else {
            @Suppress("DEPRECATION")
            Dataset.Builder(presentation()).apply {
                ids.forEach { setValue(it, null) }
                if (inline != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setInlinePresentation(inline)
                }
                setAuthentication(sender)
            }.build()
        }
        return FillResponse.Builder().addDataset(dataset).build()
    }

    /**
     * The suggestion as the keyboard shows it: Zen's icon, "Zen" and
     * "Unlock Zen", in the size and style the keyboard asked for. Null when
     * the keyboard shows no suggestions or none in a version Zen can build.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun inlinePresentation(request: FillRequest): InlinePresentation? {
        val inlineRequest = request.inlineSuggestionsRequest ?: return null
        if (inlineRequest.maxSuggestionCount < 1) {
            return null
        }
        val spec = inlineRequest.inlinePresentationSpecs.firstOrNull() ?: return null
        if (!UiVersions.getVersions(spec.style).contains(UiVersions.INLINE_UI_VERSION_1)) {
            return null
        }
        val title = getString(R.string.launcher_label)
        val subtitle = getString(R.string.biometric_unlock_reason)
        // The keyboard tints a suggestion's icon with its own colour; Zen's
        // icon has colours of its own and would come out as a flat shape.
        val icon = Icon.createWithResource(this, R.mipmap.ic_launcher)
            .setTintBlendMode(BlendMode.DST)
        val content = InlineSuggestionUi.newContentBuilder(attribution())
            .setStartIcon(icon)
            .setTitle(title)
            .setSubtitle(subtitle)
            .setContentDescription("$title, $subtitle")
            .build()
        return InlinePresentation(content.slice, spec, false)
    }

    /**
     * What a long press on the keyboard's suggestion opens (the keyboard
     * requires one, to show whose suggestion it is): Zen, as from its icon.
     */
    private fun attribution(): PendingIntent = PendingIntent.getActivity(
        this,
        ATTRIBUTION_REQUEST,
        Intent(this, MainActivity::class.java).addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP,
        ),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /**
     * The suggestion's row in the system's drop-down: Zen's icon, "Zen" and
     * "Unlock Zen" (the biometric prompt's words), nothing from the vault.
     *
     * The row brings its own background with its text colours. The system
     * inflates it with its own autofill theme over a background of its own,
     * and simple_list_item_1, whose text colour comes from that theme
     * (textAppearanceListItemSmall), showed up as an empty row in Chrome on
     * a phone: most likely a text colour that does not fit the background
     * the device draws (themes vary by maker and by night mode). A
     * background and text colours picked together are readable whatever the
     * theme. Dark or light follows the system's night mode, as this
     * service's configuration reports it.
     */
    private fun presentation(): RemoteViews {
        val night = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        return RemoteViews(packageName, R.layout.zen_autofill_suggestion).apply {
            setInt(
                R.id.zen_autofill_suggestion,
                "setBackgroundColor",
                if (night) ROW_DARK else ROW_LIGHT,
            )
            setTextViewText(R.id.zen_autofill_title, getString(R.string.launcher_label))
            setTextColor(R.id.zen_autofill_title, if (night) TITLE_DARK else TITLE_LIGHT)
            setTextViewText(R.id.zen_autofill_subtitle, getString(R.string.biometric_unlock_reason))
            setTextColor(R.id.zen_autofill_subtitle, if (night) SUBTITLE_DARK else SUBTITLE_LIGHT)
        }
    }

    /**
     * Every view of [structure] with one of [client]'s address bar ids
     * ([isAddressBarId]), hidden ones too (a hidden copy is still one too
     * many), up to [MAX_ADDRESS_BARS].
     */
    @RequiresApi(Build.VERSION_CODES.P)
    private fun addressBars(structure: AssistStructure, client: String): List<AddressBarView> {
        val found = mutableListOf<AddressBarView>()
        var visited = 0
        fun visit(node: AssistStructure.ViewNode, depth: Int) {
            if (depth > MAX_DEPTH || visited++ >= MAX_NODES || found.size >= MAX_ADDRESS_BARS) {
                return
            }
            if (isAddressBarId(client, node.idEntry)) {
                found.add(
                    AddressBarView(
                        idEntry = node.idEntry,
                        idPackage = node.idPackage,
                        idType = node.idType,
                        focused = node.isFocused,
                        webDomain = node.webDomain,
                        webScheme = node.webScheme,
                    ),
                )
            }
            for (i in 0 until node.childCount) {
                visit(node.getChildAt(i), depth + 1)
            }
        }
        for (i in 0 until structure.windowNodeCount) {
            visit(structure.getWindowNodeAt(i).rootViewNode, 0)
        }
        return found
    }

    /** The text fields of a form, in the order on the screen, with their ids. */
    @RequiresApi(Build.VERSION_CODES.P)
    private class FormReader {
        val fields = mutableListOf<AutofillField>()
        val ids = mutableListOf<AutofillId>()

        /**
         * Reads [node] and what is under it. A hidden or disabled view (and
         * everything in it) is never filled. [domain] and [scheme] are the
         * page the nearest view above reported.
         */
        fun read(node: AssistStructure.ViewNode, domain: String?, scheme: String?, depth: Int) {
            if (depth > MAX_DEPTH || fields.size >= MAX_FIELDS) {
                return
            }
            if (node.visibility != View.VISIBLE || !node.isEnabled) {
                return
            }
            val ownDomain = node.webDomain
            val pageDomain = if (ownDomain.isNullOrEmpty()) domain else ownDomain
            val pageScheme = if (ownDomain.isNullOrEmpty()) scheme else node.webScheme
            val id = node.autofillId
            if (id != null && node.autofillType == View.AUTOFILL_TYPE_TEXT) {
                val html = node.htmlInfo
                val attributes = html?.attributes
                    ?.mapNotNull { pair ->
                        val name = pair.first ?: return@mapNotNull null
                        name to (pair.second ?: "")
                    }
                    ?: emptyList()
                val words = buildList {
                    node.idEntry?.let { add(it) }
                    node.hint?.let { add(it) }
                    attributes
                        .filter { (name, _) ->
                            name.equals("name", true) || name.equals("id", true) ||
                                name.equals("placeholder", true)
                        }
                        .forEach { add(it.second) }
                }
                fields.add(
                    AutofillField(
                        index = fields.size,
                        hints = node.autofillHints?.toList() ?: emptyList(),
                        inputType = node.inputType,
                        htmlTag = html?.tag,
                        htmlAttributes = attributes,
                        words = words,
                        webDomain = pageDomain,
                        webScheme = pageScheme,
                    ),
                )
                ids.add(id)
            }
            for (i in 0 until node.childCount) {
                read(node.getChildAt(i), pageDomain, pageScheme, depth + 1)
            }
        }
    }

    companion object {
        private const val TAG = "ZenAutofill"

        /** One request code: a new suggestion cancels the one before it. */
        private const val AUTH_REQUEST = 9301

        /** The keyboard suggestion's long press (always the same intent). */
        private const val ATTRIBUTION_REQUEST = 9302

        /** Bounds for a form built to be heavy; a login form is far below. */
        private const val MAX_DEPTH = 64
        private const val MAX_FIELDS = 200

        /**
         * Views looked at for the address bar. A page with more nodes than
         * this gives no second bar beyond them, but Android puts the
         * address only on the first view with the bar's id (breadth
         * first), so a page's node far down never gets it.
         */
        private const val MAX_NODES = 20000

        // The suggestion's colours: light and dark surfaces with text well
        // above 4.5:1 on them.
        private const val ROW_LIGHT = 0xFFFFFFFF.toInt()
        private const val TITLE_LIGHT = 0xFF1F1F1F.toInt()
        private const val SUBTITLE_LIGHT = 0xFF5F6368.toInt()
        private const val ROW_DARK = 0xFF202124.toInt()
        private const val TITLE_DARK = 0xFFE8EAED.toInt()
        private const val SUBTITLE_DARK = 0xFFBDC1C6.toInt()
    }
}

/** [SigningCertificateLookup] from Android's package manager (Android 9+). */
class PackageSigningCertificates(private val pm: PackageManager) : SigningCertificateLookup {
    override fun isSignedWith(packageName: String, sha256: ByteArray): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            pm.hasSigningCertificate(packageName, sha256, PackageManager.CERT_INPUT_SHA256)
}
