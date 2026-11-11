package com.roj.zen

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.util.Log
import android.view.View
import android.view.autofill.AutofillId
import android.widget.RemoteViews
import androidx.annotation.RequiresApi

/**
 * Zen as Android's autofill service: off until the person picks Zen in
 * Android's settings ("Wypełnianie w innych aplikacjach" in "Hasła" opens
 * that page). Only the system binds it (BIND_AUTOFILL_SERVICE).
 *
 * A login form in another app or a browser gets one suggestion, "Unlock
 * Zen", that carries no login and no password: nothing is read from disk
 * here and no password exists on this side. Tapping it starts
 * [ZenAutofillActivity] (the authentication of the suggestion), which
 * brings up Zen; the person unlocks it, confirms who they are and picks
 * an entry, and only that entry comes back to fill the form.
 *
 * What the request carries to that activity is fixed here, in an immutable
 * PendingIntent the requesting app cannot change: the app's package as the
 * system reports it, the page's address only from a known browser
 * ([trustedWebOrigin]), and the two fields' ids. Each new suggestion
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
        val passwordField = form.fields[chosen.password]
        val passwordId = form.ids[chosen.password]
        val usernameId = chosen.username?.let { form.ids[it] }
        val web = trustedWebOrigin(client, passwordField.webDomain, passwordField.webScheme)

        val intent = Intent(this, ZenAutofillActivity::class.java).apply {
            putExtra(ZenAutofillActivity.EXTRA_PACKAGE, client)
            if (web != null) {
                putExtra(ZenAutofillActivity.EXTRA_WEB_DOMAIN, web.domain)
                web.scheme?.let { putExtra(ZenAutofillActivity.EXTRA_WEB_SCHEME, it) }
            }
            putExtra(ZenAutofillActivity.EXTRA_PASSWORD_ID, passwordId)
            usernameId?.let { putExtra(ZenAutofillActivity.EXTRA_USERNAME_ID, it) }
        }
        val sender = PendingIntent.getActivity(
            this,
            AUTH_REQUEST,
            intent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        ).intentSender

        @Suppress("DEPRECATION")
        val dataset = Dataset.Builder(presentation()).apply {
            // No values: only which fields the entry will fill.
            usernameId?.let { setValue(it, null) }
            setValue(passwordId, null)
            setAuthentication(sender)
        }.build()
        return FillResponse.Builder().addDataset(dataset).build()
    }

    /** The suggestion's row: "Unlock Zen" (the biometric prompt's words). */
    private fun presentation(): RemoteViews =
        RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, getString(R.string.biometric_unlock_reason))
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

        /** Bounds for a form built to be heavy; a login form is far below. */
        private const val MAX_DEPTH = 64
        private const val MAX_FIELDS = 200
    }
}
