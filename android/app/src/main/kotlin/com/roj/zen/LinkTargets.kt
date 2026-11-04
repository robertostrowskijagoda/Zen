package com.roj.zen

/**
 * Where a web link Zen itself claims goes instead of back to Zen, without
 * any Android dependency (ZenSystemBridge.openInBrowser asks the package
 * manager and hands the answers here): the app made for the link's site if
 * one opens it (one that opens it but is not a browser, such as GitHub's),
 * else the default browser; null when neither is known (a picker without
 * Zen then).
 *
 * [own] is Zen's package, [handlers] the packages that open this link,
 * [browsers] the packages that open any web page, [defaultBrowser] the one
 * Android opens any web page with (null, or the system's picker's package,
 * when none is chosen).
 */
fun linkTargetWithoutZen(
    own: String,
    handlers: List<String>,
    browsers: Set<String>,
    defaultBrowser: String?,
): String? {
    handlers.firstOrNull { it != own && it !in browsers }?.let { return it }
    return defaultBrowser?.takeIf { it != own && it in browsers }
}
