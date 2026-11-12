package com.roj.zen

/**
 * Who signs an APK (or this app), in the shape the Dart side compares
 * (apk_signature.dart, `ApkSigners`), without any Android dependency
 * (ZenUpdateBridge reads the system's verified `SigningInfo` and hands the
 * fingerprints here):
 *  - `signers`: the certificates that sign it now: the last one of a
 *    rotated key's history, or every signer of an APK with several (which
 *    cannot rotate);
 *  - `lineage`: a rotated key's history, oldest first, ending with the one
 *    signer; empty without a rotation.
 *
 * [history] is `SigningInfo.signingCertificateHistory` (Android 9 and
 * later: the system verified every link of the proof of rotation before it
 * lists it), [contentsSigners] `apkContentsSigners`, or the signatures of
 * an older Android, which knows no rotation.
 */
fun apkSignerReport(
    multipleSigners: Boolean,
    history: List<String>?,
    contentsSigners: List<String>?,
): Map<String, List<String>> {
    if (!multipleSigners && !history.isNullOrEmpty()) {
        return mapOf(
            "signers" to listOf(history.last()),
            "lineage" to if (history.size > 1) history else emptyList(),
        )
    }
    return mapOf(
        "signers" to contentsSigners.orEmpty(),
        "lineage" to emptyList(),
    )
}
